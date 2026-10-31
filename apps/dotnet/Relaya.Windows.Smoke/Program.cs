using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Relaya.Terminal;
using uniffi.relaya_core;

// Как SshSession: конструктор → подписки → Start(); вывод — в эмулятор ядра, его ответы (TakeOutput) — обратно в ConPTY.
var log = new StringBuilder();
void Log(string s) { lock (log) log.AppendLine(s); }

int Check(string name, string command, Func<string[], bool> done, Action<PseudoConsole, TerminalEmulator>? afterStart = null,
          Action<PseudoConsole, string[]>? onScreen = null, int seconds = 20)
{
    var emu = new TerminalEmulator(80, 24, 1000);
    var exited = new ManualResetEventSlim();
    var exit = -999;
    try
    {
        using var pc = new PseudoConsole(command, 80, 24);
        pc.Output += data =>
        {
            emu.Feed(data);
            var reply = emu.TakeOutput();
            if (reply.Length > 0) pc.Write(reply);
        };
        pc.Exited += c => { exit = c; exited.Set(); };
        pc.Start();
        afterStart?.Invoke(pc, emu);
        var ok = false;
        for (var i = 0; i < seconds * 10 && !ok; i++)
        {
            Thread.Sleep(100);
            var screen = emu.ScreenText().ToArray();
            onScreen?.Invoke(pc, screen);
            ok = done(screen);
            if (exited.IsSet && !ok) { Thread.Sleep(300); ok = done(emu.ScreenText().ToArray()); break; }
        }
        var text = string.Join("\n", emu.ScreenText().Select(l => l.TrimEnd())).Trim();
        var snap = emu.Snapshot();
        Log($"{name}: {(ok ? "OK" : "FAIL")} exit={(exited.IsSet ? exit.ToString() : "running")} size={snap.cols}x{snap.rows}");
        if (!ok) Log("---\n" + text + "\n---");
        return ok ? 0 : 1;
    }
    catch (Exception e)
    {
        Log($"{name}: FAIL {e}");
        return 1;
    }
}

bool HasLine(string[] screen, string line) => screen.Any(l => l.Trim() == line);

var ssh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");
if (!File.Exists(ssh)) ssh = "ssh.exe";
var failed = 0;
Log($"host: WinExe, console={(GetConsoleWindow() != IntPtr.Zero ? "yes" : "no")}, ssh={ssh}");

failed += Check("echo", "cmd /c echo relaya-smoke", s => HasLine(s, "relaya-smoke"));
failed += Check("ssh -V", $"\"{ssh}\" -V", s => s.Any(l => l.Contains("OpenSSH")));
failed += Check("ssh error", $"\"{ssh}\" -o ConnectTimeout=3 -o BatchMode=yes nobody@192.0.2.1", s => s.Any(l => l.Contains("192.0.2.1")), seconds: 30);

// Интерактив: ввод через ConPTY, ответ на экране; после старта — Resize 80×24 → 120×30, как FitToSize.
var typed = false;
failed += Check("interactive", "cmd /k prompt $G",
    s => typed && HasLine(s, "hi") && s.Any(l => l.Trim() == "hi"),
    afterStart: (pc, emu) => { Thread.Sleep(300); pc.Resize(120, 30); emu.Resize(120, 30); },
    onScreen: (pc, s) =>
    {
        if (!typed && s.Any(l => l.TrimEnd().EndsWith('>')))
        {
            typed = true;
            pc.Write(Encoding.UTF8.GetBytes("echo hi\r"));
        }
    });

// ssh на sshd в раннере (если шаг CI его поднял): вход по ключу, команда через тот же путь.
if (Environment.GetEnvironmentVariable("RELAYA_SMOKE_SSH_KEY") is { Length: > 0 } key)
{
    var user = Environment.UserName;
    failed += Check("ssh localhost", $"\"{ssh}\" -i \"{key}\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o BatchMode=yes {user}@localhost \"echo ok-from-sshd\"",
        s => HasLine(s, "ok-from-sshd"), seconds: 30);
    // Интерактивная сессия: shell на сервере, ввод команды, ответ.
    var sent = false;
    failed += Check("ssh interactive", $"\"{ssh}\" -tt -i \"{key}\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL {user}@localhost",
        s => sent && HasLine(s, "relaya-remote"),
        onScreen: (pc, s) =>
        {
            if (!sent && s.Any(l => l.TrimEnd().EndsWith('>')))
            {
                sent = true;
                pc.Write(Encoding.UTF8.GetBytes("echo relaya-remote\r"));
            }
        }, seconds: 40);
}
else Log("ssh localhost: SKIP (no RELAYA_SMOKE_SSH_KEY)");

var output = args.Length > 0 ? args[0] : "smoke.log";
File.WriteAllText(output, log.ToString());
return failed;

[System.Runtime.InteropServices.DllImport("kernel32.dll")]
static extern IntPtr GetConsoleWindow();
