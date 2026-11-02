using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Relaya.Data;

namespace Relaya.Platform;

/// Windows: OpenSSH для Windows не умеет ControlMaster, поэтому короткие команды SFTP и диска WebDAV (ls, cd, mkdir,
/// rm, rename) идут через один долгоживущий `sftp -b -` на хост; get и put — отдельным разовым sftp. Команды одного вызова пишутся в его stdin, конец вывода отмечает служебная команда
/// с уникальной меткой. Простой 5 минут, выход, блокировка и сон закрывают процесс. Статистика и карточка хоста —
/// отдельными ssh, как раньше.
internal static partial class SshMux
{
    private static readonly ConcurrentDictionary<string, Session> Sessions = new();

    private static partial IEnumerable<string> PlatformSshOptions(string alias) => Array.Empty<string>();

    private static partial Task<AppState.Result> PlatformSftp(string alias, string commands, int timeoutSeconds, CancellationToken cancel) =>
        Sessions.GetOrAdd(alias, a => new Session(a)).RunAsync(commands, timeoutSeconds, cancel);

    private static partial void PlatformCloseAll()
    {
        foreach (var alias in Sessions.Keys)
            if (Sessions.TryRemove(alias, out var s)) s.Close();
    }

    private sealed class Session
    {
        private static readonly TimeSpan Idle = TimeSpan.FromMinutes(5);
        private readonly string alias;
        private readonly SemaphoreSlim gate = new(1, 1);
        private readonly object sync = new();
        private readonly StringBuilder stdout = new(), stderr = new();
        private readonly Timer idle;
        private Process? process;
        private string marker = "";
        private bool outDone, errDone;
        private TaskCompletionSource<bool> done = new();

        public Session(string alias)
        {
            this.alias = alias;
            idle = new Timer(_ => CloseIfIdle());
        }

        public async Task<AppState.Result> RunAsync(string commands, int timeoutSeconds, CancellationToken cancel)
        {
            try { await gate.WaitAsync(cancel); }
            catch (OperationCanceledException) { return new AppState.Result(-1, "", Strings.L("Отменено")); }
            try
            {
                idle.Change(Timeout.Infinite, Timeout.Infinite);
                Process p;
                try { p = process is { HasExited: false } running ? running : Start(); }
                catch (Exception e) { return new AppState.Result(-1, "", e.Message); }
                var wait = Begin();
                // Метка — команда с ошибкой, которую пакет пропускает («-»): эхо в stdout и ошибка в stderr
                // закрывают вывод этого вызова. Каталог с меткой не существует.
                try
                {
                    await p.StandardInput.WriteAsync(commands + $"-lcd \"/relaya-{marker}\"\n");
                    await p.StandardInput.FlushAsync();
                }
                catch (Exception e) when (e is System.IO.IOException or InvalidOperationException) { }
                var exited = p.WaitForExitAsync();
                var deadline = Task.Delay(TimeSpan.FromSeconds(timeoutSeconds));
                var cancelled = Task.Delay(Timeout.Infinite, cancel).ContinueWith(_ => { }, TaskScheduler.Default);
                var first = await Task.WhenAny(wait, exited, deadline, cancelled);
                if (first == wait) return Collect(0);
                if (first == exited)
                {
                    // Ошибка команды обрывает пакет sftp — как у отдельного запуска: код выхода и вывод.
                    await Task.Delay(100); // дочитать хвост асинхронного вывода
                    process = null;
                    return Collect(p.ExitCode);
                }
                Kill(p);
                return new AppState.Result(-1, "", first == cancelled ? Strings.L("Отменено") : Strings.L("Время ожидания истекло"));
            }
            finally
            {
                idle.Change(Idle, Timeout.InfiniteTimeSpan);
                gate.Release();
            }
        }

        public void Close()
        {
            idle.Dispose();
            if (process is { } p) Kill(p);
        }

        private void CloseIfIdle()
        {
            if (!gate.Wait(0)) return;
            try
            {
                if (process is { } p) Kill(p);
                Sessions.TryRemove(new KeyValuePair<string, Session>(alias, this));
            }
            finally { gate.Release(); }
        }

        private void Kill(Process p)
        {
            process = null;
            try { p.Kill(true); } catch (InvalidOperationException) { }
            p.Dispose();
        }

        private Task<bool> Begin()
        {
            lock (sync)
            {
                marker = Guid.NewGuid().ToString("N");
                stdout.Clear();
                stderr.Clear();
                outDone = errDone = false;
                done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                return done.Task;
            }
        }

        private AppState.Result Collect(int status)
        {
            lock (sync) return new AppState.Result(status, stdout.ToString(), stderr.ToString());
        }

        private void OnLine(string? line, bool error)
        {
            if (line == null) return;
            lock (sync)
            {
                if (marker.Length > 0 && line.Contains(marker))
                {
                    if (error) errDone = true; else outDone = true;
                    if (outDone && errDone) done.TrySetResult(true);
                    return;
                }
                (error ? stderr : stdout).Append(line).Append('\n');
            }
        }

        // Пайпы перенаправления .NET создаёт ненаследуемыми со стороны приложения: другие дочерние процессы
        // их не получат. Пароль — через askpass-брокер, как у отдельного sftp.
        private Process Start()
        {
            var info = new ProcessStartInfo(AppState.SftpExe)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var a in SftpArgs) info.ArgumentList.Add(a);
            info.ArgumentList.Add(alias);
            Askpass.Configure(info, alias);
            var p = Process.Start(info) ?? throw new InvalidOperationException("sftp");
            Askpass.Started(info, p);
            p.OutputDataReceived += (_, e) => OnLine(e.Data, false);
            p.ErrorDataReceived += (_, e) => OnLine(e.Data, true);
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            process = p;
            return p;
        }
    }
}
