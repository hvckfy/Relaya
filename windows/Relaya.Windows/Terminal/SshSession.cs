using System;
using System.IO;
using System.Text;

namespace Relaya.Terminal;

/// SSH-сессия во вкладке: ssh.exe из Windows OpenSSH в ConPTY ↔ нативный TerminalView.
internal sealed class SshSession : IDisposable
{
    private readonly TerminalView view;
    private PseudoConsole? console;

    public SshSession(TerminalView view) => this.view = view;

    public void Start(string alias)
    {
        var system = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");
        var ssh = File.Exists(system) ? system : "ssh.exe";
        var size = view.Emulator.Snapshot();
        try
        {
            console = new PseudoConsole($"\"{ssh}\" \"{alias}\"", (short)size.cols, (short)size.rows);
        }
        catch (Exception e)
        {
            view.Feed(Encoding.UTF8.GetBytes($"\x1b[31mНе удалось запустить ssh: {e.Message}\x1b[0m\r\n"));
            return;
        }
        console.Output += data =>
        {
            view.Feed(data);
            var reply = view.Emulator.TakeOutput();
            if (reply.Length > 0) console.Write(reply);
        };
        console.Exited += code => view.Feed(Encoding.UTF8.GetBytes($"\r\n\x1b[2m[сессия завершена, код {code}]\x1b[0m\r\n"));
        view.Input += data => console?.Write(data);
        view.Resized += (cols, rows) => console?.Resize((short)cols, (short)rows);
    }

    public void Dispose() => console?.Dispose();
}
