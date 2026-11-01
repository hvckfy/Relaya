using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Relaya.Data;
using uniffi.relaya_core;

namespace Relaya.Platform;

/// Linux: ControlMaster, как на Mac. Каталог сокетов — ssh_mux_dir от $XDG_RUNTIME_DIR, без него — от своего каталога
/// данных (не общий /tmp); каталог не прошёл проверку ядра (0700, свой, не ссылка) — работаем без мультиплекса.
internal static partial class SshMux
{
    private static readonly Lazy<string?> Dir = new(() =>
    {
        var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        var bases = string.IsNullOrEmpty(runtime) ? new[] { AppState.Support } : new[] { runtime };
        foreach (var b in bases)
        {
            try
            {
                System.IO.Directory.CreateDirectory(b);
                return RelayaCoreMethods.SshMuxDir(b);
            }
            catch (Exception e) { Terminal.TerminalView.Trace("ssh mux dir: " + e.Message); }
        }
        return null;
    });

    // Хосты, у которых мог подняться master, — их и закрываем.
    private static readonly ConcurrentDictionary<string, string> Used = new();

    private static string? ControlPath(string alias)
    {
        if (Dir.Value is not { } dir) return null;
        var path = RelayaCoreMethods.SshMuxControlPath(dir, alias);
        Used[alias] = path;
        return path;
    }

    private static partial IEnumerable<string> PlatformSshOptions(string alias) =>
        ControlPath(alias) is { } path ? RelayaCoreMethods.SshMuxOptions(path) : Array.Empty<string>();

    private static partial Task<AppState.Result> PlatformSftp(string alias, string commands, int timeoutSeconds, CancellationToken cancel) =>
        RunSftp(alias, PlatformSshOptions(alias), commands, timeoutSeconds, cancel);

    // `ssh -O exit` для каждого хоста; master без каналов и так уходит через ControlPersist.
    private static partial void PlatformCloseAll()
    {
        foreach (var (alias, path) in Used)
        {
            Used.TryRemove(alias, out _);
            var info = new ProcessStartInfo(AppState.SshExe) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var a in RelayaCoreMethods.SshMuxExitArgs(path, alias)) info.ArgumentList.Add(a);
            try
            {
                using var p = Process.Start(info);
                p?.WaitForExit(2000);
            }
            catch (Exception e) { Terminal.TerminalView.Trace("ssh mux exit: " + e.Message); }
        }
    }
}
