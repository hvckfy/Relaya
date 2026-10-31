using System;
using System.IO;
using System.Text;
using Relaya.Platform;

namespace Relaya.Terminal;

/// SSH-сессия во вкладке: ssh.exe из Windows OpenSSH в ConPTY ↔ нативный TerminalView.
/// После разрыва Enter переподключает в той же вкладке.
internal sealed class SshSession : IDisposable
{
    private readonly TerminalView view;
    private readonly string alias;
    private PseudoConsole? console;
    private volatile bool ended;
    // Имя tmux-сессии постоянно на всю вкладку: переподключение возвращает в ту же сессию.
    private readonly string tmuxName;

    /// Сессия завершилась или переподключилась — вкладка меняет иконку.
    public event Action<bool>? StateChanged;

    public SshSession(TerminalView view, string alias)
    {
        this.view = view;
        this.alias = alias;
        tmuxName = uniffi.relaya_core.RelayaCoreMethods.TmuxSessionName(alias, Guid.NewGuid().ToString("N"));
        view.Input += OnInput;
        view.Resized += (cols, rows) => console?.Resize((short)cols, (short)rows);
    }

    public void Start()
    {
        console?.Dispose();
        ended = false;
        var system = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");
        var ssh = File.Exists(system) ? system : "ssh.exe";
        var size = view.Emulator.Snapshot();
        PseudoConsole pc;
        try
        {
            // Хост с tmux (как на Mac): сессия живёт на сервере и переживает разрыв связи.
            var command = $"\"{ssh}\" \"{alias}\"";
            if (Relaya.Data.AppState.Host(alias)?.tmux == true)
            {
                var ttl = long.TryParse(Relaya.Platform.Settings.Get("tmux.idle", "60"), out var m) ? m : 60;
                var attach = uniffi.relaya_core.RelayaCoreMethods.TmuxAttachCommand(tmuxName, ttl);
                command = $"{Arg(ssh)} -t {Arg(alias)} {Arg(attach)}";
            }
            pc = new PseudoConsole(command, (short)size.cols, (short)size.rows);
        }
        catch (Exception e)
        {
            End($"\x1b[31mНе удалось запустить ssh: {e.Message}\x1b[0m");
            return;
        }
        console = pc;
        var passwordSent = false;
        var tail = new StringBuilder();
        pc.Output += data =>
        {
            view.Feed(data);
            // Пароль из Credential Manager вводится один раз за подключение, как на Mac.
            if (!passwordSent)
            {
                tail.Append(Encoding.UTF8.GetString(data));
                if (tail.Length > 512) tail.Remove(0, tail.Length - 512);
                var text = System.Text.RegularExpressions.Regex.Replace(tail.ToString(), "\x1b\\[[0-9;?]*[A-Za-z]", "").Replace("\r", "");
                if (PasswordPrompt.Matches(text) && Relaya.Platform.CredentialStore.Read(alias) is { } password)
                {
                    passwordSent = true;
                    pc.Write(Encoding.UTF8.GetBytes(password + "\r"));
                }
            }
            var reply = view.Emulator.TakeOutput();
            if (reply.Length > 0) pc.Write(reply);
        };
        pc.Exited += code => { if (console == pc) End($"\x1b[2m[сессия завершена, код {code}]\x1b[0m"); };
        StateChanged?.Invoke(true);
    }

    private void End(string message)
    {
        ended = true;
        view.Feed(Encoding.UTF8.GetBytes($"\r\n{message}\r\n\x1b[2mEnter — переподключиться\x1b[0m\r\n"));
        StateChanged?.Invoke(false);
    }

    private void OnInput(byte[] data)
    {
        if (!ended) { console?.Write(data); return; }
        if (data.Length == 1 && data[0] == '\r') Start();
    }

    // Аргумент командной строки Windows (правила CommandLineToArgvW): кавычки и обратные слэши перед ними.
    private static string Arg(string a)
    {
        var sb = new StringBuilder("\"");
        var slashes = 0;
        foreach (var c in a)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { sb.Append('\\', slashes * 2 + 1).Append('"'); }
            else { sb.Append('\\', slashes).Append(c); }
            slashes = 0;
        }
        return sb.Append('\\', slashes * 2).Append('"').ToString();
    }

    public void Dispose() => console?.Dispose();
}
