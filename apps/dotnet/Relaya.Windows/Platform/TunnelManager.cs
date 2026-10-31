using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Linq;
using uniffi.relaya_core;

namespace Relaya.Platform;

/// SSH-туннели (-L/-R/-D) как фоновые `ssh -N`: те же аргументы ядра, что на Mac. Автостарт — при запуске приложения.
internal sealed class TunnelManager
{
    public static TunnelManager Shared { get; } = new();

    public enum State { Stopped, Starting, Running, Failed }

    private readonly ConcurrentDictionary<string, (Process Process, State State, string? Error)> running = new();

    public event Action? Changed;

    public (State State, string? Error) StatusOf(Tunnel t) =>
        running.TryGetValue(t.id, out var r) ? (r.State, r.Error) : (State.Stopped, null);

    public void StartAuto()
    {
        foreach (var t in Data.AppState.Tunnels.Where(t => t.autoStart)) Start(t);
    }

    public void Start(Tunnel t)
    {
        if (running.TryGetValue(t.id, out var r) && r.State is State.Running or State.Starting) return;
        var info = new ProcessStartInfo(Data.AppState.SshExe)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true,
        };
        var passwordOnly = Askpass.PasswordOnly(t.hostAlias);
        foreach (var a in RelayaCoreMethods.TunnelSshArguments(t, passwordOnly)) info.ArgumentList.Add(a);
        // Опции «только пароль» уже в аргументах ядра — askpass нужен только для самого пароля.
        if (passwordOnly) { Askpass.SetEnvironment(info, t.hostAlias); }
        Process p;
        try { p = Process.Start(info)!; }
        catch (Exception e) { running[t.id] = (null!, State.Failed, e.Message); Changed?.Invoke(); return; }
        p.EnableRaisingEvents = true;
        var error = new System.Text.StringBuilder();
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (error) error.AppendLine(e.Data); };
        p.BeginErrorReadLine();
        running[t.id] = (p, State.Starting, null);
        p.Exited += (_, _) =>
        {
            p.WaitForExit(); // дочитать stderr: Exited приходит раньше последних ErrorDataReceived
            string message;
            lock (error) message = error.ToString();
            if (running.TryGetValue(t.id, out var cur) && cur.Process == p)
                running[t.id] = (p, State.Failed, SshErrors.Describe(message, Strings.L("ssh завершился, код %@", p.ExitCode)));
            Changed?.Invoke();
        };
        // ExitOnForwardFailure: если через 3 секунды ssh жив — туннель поднят.
        System.Threading.Tasks.Task.Delay(3000).ContinueWith(_ =>
        {
            if (!p.HasExited && running.TryGetValue(t.id, out var cur) && cur.Process == p)
            {
                running[t.id] = (p, State.Running, null);
                Changed?.Invoke();
            }
        });
        Changed?.Invoke();
    }

    public void Stop(string id)
    {
        if (running.TryRemove(id, out var r) && r.Process is { HasExited: false } p)
            try { p.Kill(true); } catch (InvalidOperationException) { }
        Changed?.Invoke();
    }

    public void StopAll()
    {
        foreach (var id in running.Keys.ToList()) Stop(id);
    }
}
