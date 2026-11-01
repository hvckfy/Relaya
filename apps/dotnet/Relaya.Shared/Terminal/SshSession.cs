using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using Relaya.Platform;
using static Relaya.Strings;

namespace Relaya.Terminal;

/// SSH-сессия во вкладке: ssh (Windows OpenSSH / системный на Linux) в псевдотерминале ↔ нативный TerminalView.
/// После разрыва Enter переподключает в той же вкладке.
internal sealed class SshSession : IDisposable
{
    private readonly TerminalView view;
    private readonly string alias;
    private IPty? console;
    private volatile bool ended;
    // Имя tmux-сессии постоянно на всю вкладку: переподключение возвращает в ту же сессию.
    private readonly string tmuxName;

    /// Имя tmux-сессии вкладки — чтобы уборка старых сессий не трогала открытые.
    public string TmuxName => tmuxName;
    // Переключатель вкладки (Е.11) сильнее настройки хоста; null — как в хосте.
    private bool? tmuxOverride;
    // 4.22, как на Mac: сервер оборвал вход после перебора ключей агента — до конца вкладки входим только по паролю.
    private bool passwordOnly;
    private bool retryPasswordOnly;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue ui;
    public event Action? PasswordOnlySwitched;

    // 4.15, как на Mac: обрыв (ssh вышел с 255) после входа или через 10 с — переподключение через 5 с с отсчётом.
    private bool sessionLoggedIn;
    private DateTime startedAt;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? reconnectTimer;
    private int reconnectLeft;
    // Лимит, как на Mac (аудит безопасности): больше 10 коротких сессий (< 60 с) подряд — ждём ручного переподключения.
    private int shortRuns;
    /// Секунд до переподключения; null — отсчёта нет.
    public event Action<int?>? ReconnectCountdown;

    public void CancelReconnect()
    {
        reconnectTimer?.Stop();
        reconnectTimer = null;
        ReconnectCountdown?.Invoke(null);
    }

    private void ScheduleReconnect()
    {
        CancelReconnect();
        reconnectLeft = 5;
        reconnectTimer = ui.CreateTimer();
        reconnectTimer.Interval = TimeSpan.FromSeconds(1);
        reconnectTimer.Tick += (_, _) =>
        {
            if (--reconnectLeft > 0) { ReconnectCountdown?.Invoke(reconnectLeft); return; }
            CancelReconnect();
            Start();
        };
        reconnectTimer.Start();
        ReconnectCountdown?.Invoke(reconnectLeft);
    }

    public bool UsesTmux => tmuxOverride ?? Relaya.Data.AppState.Host(alias)?.tmux == true;

    /// Е.11, как на Mac: вкладка переподключается — при включении внутри tmux, при выключении сессия на сервере закрывается.
    public void SetTmux(bool on)
    {
        if (UsesTmux == on) return;
        tmuxOverride = on;
        Start();
        if (!on) _ = KillTmuxAsync();
    }

    private async System.Threading.Tasks.Task KillTmuxAsync()
    {
        var r = await Relaya.Data.AppState.RunOnHost(alias, uniffi.relaya_core.RelayaCoreMethods.TmuxKillCommand(new() { tmuxName }));
        if (r.Status != 0) Relaya.Terminal.TerminalView.Trace("tmux kill: " + r.Stderr.Trim());
    }

    /// 4.16 «Отсоединить и оставить на сервере»: сессия живёт сутки без подключения, уборка её не трогает.
    public System.Threading.Tasks.Task<Relaya.Data.AppState.Result> KeepTmuxAsync() =>
        Relaya.Data.AppState.RunOnHost(alias, uniffi.relaya_core.RelayaCoreMethods.TmuxKeepCommand(tmuxName));

    /// Сессия завершилась или переподключилась — вкладка меняет иконку.
    public event Action<bool>? StateChanged;

    /// После входа удалённая программа (su, sudo, mysql…) спросила пароль — вкладка предлагает подставить пароль хоста.
    public event Action? PasswordRequested;

    /// Вошли по паролю, а ключа у хоста нет — предложить «Настроить вход по ключу» (как на Mac).
    public event Action? KeySetupOffered;

    /// Первое подключение: ssh спрашивает, доверять ли ключу сервера; аргумент — отпечаток (SHA256:…).
    public event Action<string>? HostKeyRequested;
    /// Ключ сервера не совпал с known_hosts (4.19): ssh не подключится — показать предупреждение, как на Mac.
    public event Action? HostKeyChanged;

    /// Ответ на вопрос о ключе сервера — в ту же сессию.
    public void AnswerHostKey(bool trust)
    {
        if (!ended) console?.Write(Encoding.UTF8.GetBytes(trust ? "yes\r" : "no\r"));
    }

    // Отпечаток из «… key fingerprint is SHA256:abc.» — как SessionController.fingerprint на Mac.
    private static string? Fingerprint(string text)
    {
        var i = text.LastIndexOf("key fingerprint is ", StringComparison.Ordinal);
        if (i < 0) return null;
        var rest = text[(i + "key fingerprint is ".Length)..];
        var end = rest.IndexOfAny(new[] { ' ', '\n', '\t' });
        return (end < 0 ? rest : rest[..end]).TrimEnd('.');
    }

    private IPty? asked;
    // Последняя строка вывода — запрос пароля: такой ввод не рассылается в другие терминалы.
    private volatile bool secretPrompt;

    private readonly object portsLock = new();
    private List<long> ports = new();

    /// Порты сервера, замеченные в выводе (`localhost:3000`, `0.0.0.0:5173`) — до 4, последние первыми (local_ports_find ядра).
    public IReadOnlyList<long> Ports { get { lock (portsLock) return ports.ToList(); } }

    /// Список портов изменился (из потока вывода).
    public event Action? PortsChanged;

    /// Сейчас вводится пароль (ssh, sudo, su) — рассылка из этого терминала на паузе.
    public bool SecretPrompt => secretPrompt;

    /// Ввод, разосланный из другого терминала: прямо в процесс, без повторной рассылки.
    public void Receive(byte[] data)
    {
        if (!ended) console?.Write(data);
    }

    /// Подставить сохранённый пароль — только в ту же сессию, где был запрос (не в переподключённую).
    /// До входа: сервер спрашивает пароль, а сохранённого нет (true) или сохранённый не подошёл (false) — 4.20.
    public event Action<bool>? LoginPasswordNeeded;

    /// Ввести пароль в запрос ssh (из баннера «Ввести и сохранить…» / «Ввести новый…»); сохранить — по выбору.
    public void TypeLoginPassword(string password, bool save)
    {
        if (save) Relaya.Platform.CredentialStore.Write(alias, password);
        if (!ended) console?.Write(Encoding.UTF8.GetBytes(password + "\r"));
    }

    public void SendPassword()
    {
        if (asked is { } pc && pc == console && !ended && Relaya.Platform.CredentialStore.Read(alias) is { } password)
            pc.Write(Encoding.UTF8.GetBytes(password + "\r"));
        asked = null;
    }

    public SshSession(TerminalView view, string alias)
    {
        this.view = view;
        this.alias = alias;
        ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread(); // создаётся на UI-потоке вкладки
        tmuxName = uniffi.relaya_core.RelayaCoreMethods.TmuxSessionName(alias, Guid.NewGuid().ToString("N"));
        view.Input += OnInput;
        view.Resized += (cols, rows) => console?.Resize((short)cols, (short)rows);
        Broadcast.Register(this);
    }

    public void Start()
    {
        CancelReconnect();
        sessionLoggedIn = false;
        startedAt = DateTime.UtcNow;
        console?.Dispose();
        ended = false;
        var ssh = Relaya.Data.AppState.SshExe;
        var size = view.Emulator.Snapshot();
        IPty pc;
        try
        {
            // Хост с tmux (как на Mac): сессия живёт на сервере и переживает разрыв связи.
            // Только пароль: сохранён пароль, а ключа у хоста нет — ssh-agent не перебирает ключи,
            // и сервер не рвёт вход с «Too many authentication failures» до запроса пароля.
            var host = Relaya.Data.AppState.Host(alias);
            var options = passwordOnly || Askpass.PasswordOnly(alias)
                ? uniffi.relaya_core.RelayaCoreMethods.PasswordOnlyOptions().ToArray()
                : [];
            string[] argv = [ssh, .. options, alias];
            if (UsesTmux)
            {
                var ttl = long.TryParse(Relaya.Platform.Settings.Get("tmux.idle", "60"), out var m) ? m : 60;
                var attach = uniffi.relaya_core.RelayaCoreMethods.TmuxAttachCommand(tmuxName, ttl);
                argv = [ssh, .. options, "-t", alias, attach];
            }
            pc = Pty.Spawn(argv, (short)size.cols, (short)size.rows);
        }
        catch (Exception e)
        {
            End("\x1b[31m" + L("Не удалось запустить ssh: %@", e.Message) + "\x1b[0m");
            return;
        }
        console = pc;
        var passwordSent = false;
        var offeredLoginPassword = false;
        var warnedKeyChanged = false;
        var autofill = Askpass.CanAutofill(alias); // M8-1: не для хостов с ProxyCommand/LocalCommand
        var loggedIn = false;
        var sawPasswordPrompt = false;
        var tail = new StringBuilder();
        var decoder = Encoding.UTF8.GetDecoder();
        pc.Output += data =>
        {
            // Decoder с состоянием: многобайтовый символ на границе кусков не превращается в «�» (С6).
            var chars = new char[decoder.GetCharCount(data, 0, data.Length)];
            decoder.GetChars(data, 0, data.Length, chars, 0);
            tail.Append(chars);
            if (tail.Length > 512) tail.Remove(0, tail.Length - 512);
            // П-7: признаки считаются один раз на кусок; без ESC в хвосте регулярка не нужна.
            var text = StripCsi(tail.ToString()).Replace("\r", "");
            var secret = uniffi.relaya_core.RelayaCoreMethods.TerminalSecretPrompt(text);
            var prompt = PasswordPrompt.Matches(text);
            // Пауза рассылки ставится до того, как запрос появится на экране: ответ на него не успеет уйти в другие
            // терминалы, даже если набран сразу (L-SEC-1, гонка первого символа).
            if (secret) secretPrompt = true;
            view.Feed(data);
            // До входа пароль из Credential Manager вводится сам, один раз (только запрос самого ssh).
            // Вход выполнен — признак ядра (C23): приглашение shell с курсором после него, без вопросов о пароле/ключе.
            if (!loggedIn && prompt) sawPasswordPrompt = true;
            if (!loggedIn && view.Emulator.LoginReady())
            {
                loggedIn = true;
                sessionLoggedIn = true;
                if (sawPasswordPrompt && Relaya.Data.AppState.Host(alias)?.identityFile == null
                    && Relaya.Platform.Settings.Get("terminal.offerKeySetup", "1") == "1")
                {
                    try { KeySetupOffered?.Invoke(); }
                    catch (Exception e) { Relaya.Terminal.TerminalView.Trace("KeySetupOffered: " + e.GetType().Name); }
                }
            }
            if (!loggedIn && !passwordOnly && text.Contains("Too many authentication failures"))
            {
                passwordOnly = true;
                retryPasswordOnly = true;
            }
            if (!loggedIn && !warnedKeyChanged && text.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
            {
                warnedKeyChanged = true;
                try { HostKeyChanged?.Invoke(); }
                catch (Exception e) { Relaya.Terminal.TerminalView.Trace("HostKeyChanged: " + e.GetType().Name); }
            }
            // Вопрос о ключе сервера при первом подключении — окно с отпечатком, а не ввод «yes» вслепую.
            if (!loggedIn && text.Contains("Are you sure you want to continue connecting") && text.TrimEnd().EndsWith('?'))
            {
                var fp = Fingerprint(text) ?? L("неизвестен");
                tail.Clear();
                try { HostKeyRequested?.Invoke(fp); }
                catch (Exception e) { Relaya.Terminal.TerminalView.Trace("HostKeyRequested: " + e.GetType().Name); }
            }
            // До входа (запросы самого ssh: пароль, passphrase, 2FA) — рассылки нет вовсе; после — по правилу ядра
            // terminal_secret_prompt, общему для Mac, Windows и Linux (L-SEC-1).
            secretPrompt = !loggedIn || secret;
            NotePorts(new string(chars));
            Log(chars);
            if (!loggedIn && !passwordSent && prompt && autofill && Relaya.Platform.CredentialStore.Read(alias) is { } password)
            {
                passwordSent = true;
                tail.Clear();
                pc.Write(Encoding.UTF8.GetBytes(password + "\r"));
            }
            else if (!loggedIn && prompt && !offeredLoginPassword)
            {
                // Пароля нет — «Ввести и сохранить…»; подставленный уже не подошёл (ssh спрашивает снова) — «Ввести новый…».
                offeredLoginPassword = true;
                var rejected = passwordSent;
                tail.Clear();
                try { LoginPasswordNeeded?.Invoke(!rejected); }
                catch (Exception e) { Relaya.Terminal.TerminalView.Trace("LoginPasswordNeeded: " + e.GetType().Name); }
            }
            else if (loggedIn && autofill && PasswordPrompt.IsAnyPasswordPrompt(text))
            {
                // После входа — только по согласию человека (баннер «Подставить» / «Нет»).
                tail.Clear();
                asked = pc;
                try { PasswordRequested?.Invoke(); }
                catch (Exception e) { Relaya.Terminal.TerminalView.Trace("PasswordRequested: " + e.GetType().Name); }
            }
            var reply = view.Emulator.TakeOutput();
            if (reply.Length > 0) pc.Write(reply);
        };
        // Сбой в обработке вывода — не немой пустой экран: текст ошибки прямо в терминал.
        pc.HandlerFailed += e =>
        {
            try { view.Feed(Encoding.UTF8.GetBytes("\r\n\x1b[31m" + L("Relaya: ошибка вывода терминала: %@", e.Message) + "\x1b[0m\r\n")); }
            catch (Exception) { }
        };
        pc.Exited += code =>
        {
            if (console != pc) return;
            if (retryPasswordOnly)
            {
                retryPasswordOnly = false;
                try { PasswordOnlySwitched?.Invoke(); }
                catch (Exception e) { Relaya.Terminal.TerminalView.Trace("PasswordOnlySwitched: " + e.GetType().Name); }
                ui.TryEnqueue(Start);
                return;
            }
            End("\x1b[2m" + L("[сессия завершена, код %@]", code) + "\x1b[0m");
            shortRuns = DateTime.UtcNow - startedAt < TimeSpan.FromSeconds(60) ? shortRuns + 1 : 0;
            if (code == 255 && shortRuns <= 10 && Relaya.Platform.Settings.Get("terminal.autoReconnect", "1") == "1"
                && (sessionLoggedIn || DateTime.UtcNow - startedAt > TimeSpan.FromSeconds(10)))
                ui.TryEnqueue(ScheduleReconnect);
        };
        pc.Start();
        StateChanged?.Invoke(true);
    }

    private static readonly System.Text.RegularExpressions.Regex Csi =
        new("\x1b\\[[0-9;?]*[A-Za-z]", System.Text.RegularExpressions.RegexOptions.Compiled);

    // Escape-последовательности CSI убираются только если ESC вообще есть.
    private static string StripCsi(string text) => text.Contains('\x1b') ? Csi.Replace(text, "") : text;

    // Порты из нового куска вывода (без escape-последовательностей): новые — в начало списка.
    private void NotePorts(string chunk)
    {
        // Порт — это цифры: кусок без цифр (набор, перерисовка) не идёт в ядро.
        if (!chunk.AsSpan().ContainsAnyInRange('0', '9')) return;
        var plain = StripCsi(chunk);
        var found = uniffi.relaya_core.RelayaCoreMethods.LocalPortsFind(plain);
        if (found.Count == 0) return;
        bool changed;
        lock (portsLock)
        {
            var next = found.AsEnumerable().Reverse().Concat(ports.Where(p => !found.Contains(p))).Distinct().Take(4).ToList();
            changed = !next.SequenceEqual(ports);
            ports = next;
        }
        if (changed) PortsChanged?.Invoke();
    }

    private void End(string message)
    {
        ended = true;
        view.Feed(Encoding.UTF8.GetBytes($"\r\n{message}\r\n\x1b[2m{L("Enter — переподключиться")}\x1b[0m\r\n"));
        StateChanged?.Invoke(false);
    }

    private void OnInput(byte[] data)
    {
        if (!ended)
        {
            console?.Write(data);
            if (!view.IsProgrammaticInput && !secretPrompt) Broadcast.Send(this, data);
            return;
        }
        if (data.Length == 1 && data[0] == '\r') Start();
    }

    // --- Запись сессии в файл (чек-лист 4.14, как на Mac): очищенный от управляющих последовательностей вывод ---

    private readonly object logLock = new();
    private FileStream? log;

    /// Файл записи; null — запись выключена.
    public string? RecordingPath { get; private set; }

    /// Запись включилась или выключилась.
    public event Action? RecordingChanged;

    /// Папка записей: «Документы/Relaya Logs», как на Mac.
    public static string RecordingsFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Relaya Logs");

    public void ToggleRecording()
    {
        lock (logLock)
        {
            if (log != null)
            {
                log.Dispose();
                log = null;
                RecordingPath = null;
            }
            else
            {
                Directory.CreateDirectory(RecordingsFolder);
                // Своё имя у каждой сессии и CreateNew (O_EXCL): две вкладки одного хоста не пишут в один файл; 0600.
                var path = Path.Combine(RecordingsFolder, $"{alias} {DateTime.Now:yyyy-MM-dd HH-mm-ss} {Guid.NewGuid().ToString("N")[..6]}.log");
                var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.Read };
                if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
                try { log = new FileStream(path, options); RecordingPath = path; }
                catch (Exception e) { TerminalView.Trace("recording: " + e.Message); }
            }
        }
        RecordingChanged?.Invoke();
    }

    private static readonly System.Text.RegularExpressions.Regex Escapes =
        new(@"\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(\x07|\x1B\\)|\x1B[()][A-Z0-9]|\x1B[=>]");

    private void Log(char[] chars)
    {
        lock (logLock)
        {
            if (log == null) return;
            var text = Escapes.Replace(new string(chars), "").Replace("\r\n", "\n").Replace("\r", "");
            try { log.Write(Encoding.UTF8.GetBytes(text)); log.Flush(); }
            catch (Exception e) { TerminalView.Trace("recording: " + e.Message); }
        }
    }

    public void Dispose()
    {
        reconnectTimer?.Stop();
        Broadcast.Unregister(this);
        lock (logLock) { log?.Dispose(); log = null; }
        console?.Dispose();
    }
}
