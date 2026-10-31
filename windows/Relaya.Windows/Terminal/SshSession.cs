using System;
using System.IO;
using System.Text;

namespace Relaya.Terminal;

/// SSH-сессия во вкладке: ssh.exe из Windows OpenSSH в ConPTY ↔ нативный TerminalView.
/// После разрыва Enter переподключает в той же вкладке.
internal sealed class SshSession : IDisposable
{
    private readonly TerminalView view;
    private readonly string alias;
    private PseudoConsole? console;
    private volatile bool ended;

    /// Сессия завершилась или переподключилась — вкладка меняет иконку.
    public event Action<bool>? StateChanged;

    public SshSession(TerminalView view, string alias)
    {
        this.view = view;
        this.alias = alias;
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
            pc = new PseudoConsole($"\"{ssh}\" \"{alias}\"", (short)size.cols, (short)size.rows);
        }
        catch (Exception e)
        {
            End($"\x1b[31mНе удалось запустить ssh: {e.Message}\x1b[0m");
            return;
        }
        console = pc;
        pc.Output += data =>
        {
            view.Feed(data);
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

    public void Dispose() => console?.Dispose();
}
