using System;
using System.IO;
using System.Text;
using System.Threading;
using Relaya.Terminal;

// Порядок как в SshSession: конструктор → подписки → Start(). Вывод должен прийти до выхода процесса.
static int Check(string name, string command, string expect, int seconds)
{
    var output = new StringBuilder();
    var exited = new ManualResetEventSlim();
    var exitCode = -1;
    using var pc = new PseudoConsole(command, 120, 30);
    pc.Output += data => { lock (output) output.Append(Encoding.UTF8.GetString(data)); };
    pc.Exited += code => { exitCode = code; exited.Set(); };
    pc.Start();
    if (!exited.Wait(TimeSpan.FromSeconds(seconds))) Console.WriteLine($"{name}: no exit in {seconds}s");
    Thread.Sleep(500); // хвост вывода
    string text;
    lock (output) text = output.ToString();
    var ok = text.Contains(expect, StringComparison.OrdinalIgnoreCase);
    Console.WriteLine($"{name}: exit={exitCode} bytes={text.Length} {(ok ? "OK" : "FAIL")}");
    if (!ok) Console.WriteLine(text.Replace("\x1b", "\\e"));
    return ok ? 0 : 1;
}

var ssh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");
if (!File.Exists(ssh)) ssh = "ssh.exe";
var failed = 0;
failed += Check("echo", "cmd /c echo relaya-smoke", "relaya-smoke", 15);
failed += Check("ssh -V", $"\"{ssh}\" -V", "OpenSSH", 15);
// Ошибка входа должна быть видна в терминале, а не только код 255.
failed += Check("ssh error", $"\"{ssh}\" -o ConnectTimeout=3 -o BatchMode=yes nobody@192.0.2.1", "192.0.2.1", 30);
return failed;
