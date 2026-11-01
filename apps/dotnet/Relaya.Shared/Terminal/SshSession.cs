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

    /// Сессия завершилась или переподключилась — вкладка меняет иконку.
    public event Action<bool>? StateChanged;

    /// После входа удалённая программа (su, sudo, mysql…) спросила пароль — вкладка предлагает подставить пароль хоста.
    public event Action? PasswordRequested;

    /// Первое подключение: ssh спрашивает, доверять ли ключу сервера; аргумент — отпечаток (SHA256:…).
    public event Action<string>? HostKeyRequested;

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
        tmuxName = uniffi.relaya_core.RelayaCoreMethods.TmuxSessionName(alias, Guid.NewGuid().ToString("N"));
        view.Input += OnInput;
        view.Resized += (cols, rows) => console?.Resize((short)cols, (short)rows);
        Broadcast.Register(this);
    }

    public void Start()
    {
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
            var options = Askpass.PasswordOnly(alias)
                ? uniffi.relaya_core.RelayaCoreMethods.PasswordOnlyOptions().ToArray()
                : [];
            string[] argv = [ssh, .. options, alias];
            if (host?.tmux == true)
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
        var autofill = Askpass.CanAutofill(alias); // M8-1: не для хостов с ProxyCommand/LocalCommand
        var loggedIn = false;
        var tail = new StringBuilder();
        var decoder = Encoding.UTF8.GetDecoder();
        pc.Output += data =>
        {
            view.Feed(data);
            // Decoder с состоянием: многобайтовый символ на границе кусков не превращается в «�» (С6).
            var chars = new char[decoder.GetCharCount(data, 0, data.Length)];
            decoder.GetChars(data, 0, data.Length, chars, 0);
            tail.Append(chars);
            if (tail.Length > 512) tail.Remove(0, tail.Length - 512);
            var text = System.Text.RegularExpressions.Regex.Replace(tail.ToString(), "\x1b\\[[0-9;?]*[A-Za-z]", "").Replace("\r", "");
            // До входа пароль из Credential Manager вводится сам, один раз (только запрос самого ssh).
            // Вход выполнен — признак ядра (C23): приглашение shell с курсором после него, без вопросов о пароле/ключе.
            if (!loggedIn && view.Emulator.LoginReady()) loggedIn = true;
            // Вопрос о ключе сервера при первом подключении — окно с отпечатком, а не ввод «yes» вслепую.
            if (!loggedIn && text.Contains("Are you sure you want to continue connecting") && text.TrimEnd().EndsWith('?'))
            {
                var fp = Fingerprint(text) ?? L("неизвестен");
                tail.Clear();
                try { HostKeyRequested?.Invoke(fp); }
                catch (Exception e) { Relaya.Terminal.TerminalView.Trace("HostKeyRequested: " + e.GetType().Name); }
            }
            // До входа (запросы самого ssh: пароль, passphrase, 2FA) — рассылки нет вовсе; после — по широкому правилу (L-SEC-1).
            secretPrompt = !loggedIn || PasswordPrompt.IsSecretPrompt(text);
            NotePorts(new string(chars));
            if (!loggedIn && !passwordSent && PasswordPrompt.Matches(text) && autofill && Relaya.Platform.CredentialStore.Read(alias) is { } password)
            {
                passwordSent = true;
                tail.Clear();
                pc.Write(Encoding.UTF8.GetBytes(password + "\r"));
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
        pc.Exited += code => { if (console == pc) End("\x1b[2m" + L("[сессия завершена, код %@]", code) + "\x1b[0m"); };
        pc.Start();
        StateChanged?.Invoke(true);
    }

    // Порты из нового куска вывода (без escape-последовательностей): новые — в начало списка.
    private void NotePorts(string chunk)
    {
        var plain = System.Text.RegularExpressions.Regex.Replace(chunk, "\x1b\\[[0-9;?]*[A-Za-z]", "");
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

    public void Dispose()
    {
        Broadcast.Unregister(this);
        console?.Dispose();
    }
}
