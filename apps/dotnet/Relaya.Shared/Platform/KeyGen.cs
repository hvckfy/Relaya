using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace Relaya.Platform;

/// Создание ключа ed25519 без passphrase в argv (S: «ssh-keygen -N — не в командной строке»).
/// Пустая passphrase — `-N ""` (секрета нет). Иначе ssh-keygen запускается в псевдотерминале и получает
/// passphrase как ввод с клавиатуры на свои два запроса — её не видно ни в списке процессов, ни в окружении.
internal static class KeyGen
{
    public static async Task<(bool Ok, string Error)> CreateAsync(string path, string comment, string passphrase)
    {
        if (passphrase.Length == 0)
        {
            var r = await Data.AppState.Run(Data.AppState.KeygenExe, new[] { "-t", "ed25519", "-f", path, "-C", comment, "-N", "", "-q" }, null, null, 30);
            return (r.Status == 0, r.Stderr.Trim());
        }
        var exited = new TaskCompletionSource<int>();
        var output = new StringBuilder();
        var answered = 0;
        using var pty = Terminal.Pty.Spawn(new[] { Data.AppState.KeygenExe, "-t", "ed25519", "-f", path, "-C", comment, "-q" }, 120, 30);
        pty.Output += data =>
        {
            string tail;
            lock (output) { output.Append(Encoding.UTF8.GetString(data)); tail = output.ToString(); }
            // «Enter passphrase…» и «Enter same passphrase again:» — отвечаем на каждый запрос по одному разу.
            var prompts = Count(tail, "passphrase");
            while (answered < Math.Min(prompts, 2))
            {
                answered++;
                pty.Write(Encoding.UTF8.GetBytes(passphrase + "\r"));
            }
        };
        pty.Exited += code => exited.TrySetResult(code);
        pty.Start();
        var done = await Task.WhenAny(exited.Task, Task.Delay(TimeSpan.FromSeconds(30)));
        var ok = done == exited.Task && exited.Task.Result == 0 && File.Exists(path) && File.Exists(path + ".pub");
        string text;
        lock (output) text = output.ToString();
        return (ok, ok ? "" : System.Text.RegularExpressions.Regex.Replace(text, "\x1b\\[[0-9;?]*[A-Za-z]", "").Trim());
    }

    /// ssh-add ключа с passphrase: тоже вводом в псевдотерминал (ssh-add не читает passphrase из stdin).
    public static async Task<bool> AddToAgentAsync(string path, string passphrase)
    {
        var exited = new TaskCompletionSource<int>();
        var output = new StringBuilder();
        var answered = false;
        using var pty = Terminal.Pty.Spawn(new[] { Data.AppState.SshAddExe, path }, 120, 30);
        pty.Output += data =>
        {
            string tail;
            lock (output) { output.Append(Encoding.UTF8.GetString(data)); tail = output.ToString(); }
            if (!answered && tail.Contains("passphrase", StringComparison.OrdinalIgnoreCase))
            {
                answered = true;
                pty.Write(Encoding.UTF8.GetBytes(passphrase + "\r"));
            }
        };
        pty.Exited += code => exited.TrySetResult(code);
        pty.Start();
        var done = await Task.WhenAny(exited.Task, Task.Delay(TimeSpan.FromSeconds(20)));
        return done == exited.Task && exited.Task.Result == 0;
    }

    private static int Count(string text, string word)
    {
        var n = 0;
        for (var i = text.IndexOf(word, StringComparison.OrdinalIgnoreCase); i >= 0; i = text.IndexOf(word, i + word.Length, StringComparison.OrdinalIgnoreCase)) n++;
        return n;
    }
}
