using System;
using System.Text;
using System.Threading;
using Relaya.Terminal;

// Порядок как в SshSession: конструктор → подписки → Start(). Вывод должен прийти до выхода процесса.
static int Check(string name, string[] argv, string expect, int seconds, byte[]? input = null)
{
    var output = new StringBuilder();
    var exited = new ManualResetEventSlim();
    var exitCode = -1;
    using var pty = new UnixPty(argv, 120, 30);
    pty.Output += data => { lock (output) output.Append(Encoding.UTF8.GetString(data)); };
    pty.Exited += code => { exitCode = code; exited.Set(); };
    pty.Start();
    if (input != null) pty.Write(input);
    if (!exited.Wait(TimeSpan.FromSeconds(seconds))) Console.WriteLine($"{name}: no exit in {seconds}s");
    Thread.Sleep(500); // хвост вывода
    string text;
    lock (output) text = output.ToString();
    var ok = text.Contains(expect, StringComparison.OrdinalIgnoreCase);
    Console.WriteLine($"{name}: exit={exitCode} bytes={text.Length} {(ok ? "OK" : "FAIL")}");
    if (!ok) Console.WriteLine(text.Replace("\x1b", "\\e"));
    return ok ? 0 : 1;
}

var failed = 0;
failed += Check("echo", ["echo", "relaya-smoke"], "relaya-smoke", 15);
// Управляющий терминал и размер окна: без них ssh не спросит пароль и не узнает ширину.
failed += Check("tty", ["sh", "-c", "tty; stty size"], "30 120", 15);
failed += Check("input", ["sh", "-c", "read x; echo got-$x"], "got-ping", 15, Encoding.UTF8.GetBytes("ping\n"));
failed += Check("ssh -V", ["ssh", "-V"], "OpenSSH", 15);
// Ошибка входа должна быть видна в терминале, а не только код 255.
failed += Check("ssh error", ["ssh", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes", "nobody@192.0.2.1"], "192.0.2.1", 30);
return failed;
