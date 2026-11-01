using System;
using System.Diagnostics;
using System.Threading;

namespace Relaya.Platform;

internal static partial class ConsentGrace
{
    private static Process? monitor;

    /// Блокировка сеанса и сон закрывают окно доверия: сигналы logind (Session.Lock, Manager.PrepareForSleep) через
    /// `gdbus monitor` (glib2, зависимость пакета). Без gdbus окно просто живёт до своего срока — и пишется в трассировку.
    public static partial void WatchSessionLock()
    {
        if (monitor != null) return;
        var info = new ProcessStartInfo("gdbus") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "monitor", "--system", "--dest", "org.freedesktop.login1" }) info.ArgumentList.Add(a);
        try { monitor = Process.Start(info); }
        catch (Exception e) { Trace.WriteLine($"ConsentGrace: gdbus недоступен — {e.Message}"); LockWatchMissing = true; return; }
        if (monitor == null) return;
        var reader = monitor.StandardOutput;
        new Thread(() =>
        {
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                if (line.Contains("org.freedesktop.login1.Session.Lock") || line.Contains("PrepareForSleep (true"))
                    Reset();
            }
        }) { IsBackground = true, Name = "logind lock monitor" }.Start();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => { try { monitor?.Kill(); } catch (InvalidOperationException) { } };
    }
}
