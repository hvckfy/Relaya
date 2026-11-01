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
    // Туннели, которых нет в tunnels.json (удалённые столы, id `desktop:<id>`): видны в списке, пока живы.
    private readonly ConcurrentDictionary<string, Tunnel> temporary = new();

    public System.Collections.Generic.List<Tunnel> Temporary => temporary.Values.OrderBy(t => t.name).ToList();

    /// Временный туннель: уже работающий с тем же id переиспользуется (тот же локальный порт).
    public Tunnel StartTemporary(Tunnel t)
    {
        if (temporary.TryGetValue(t.id, out var existing) && StatusOf(existing).State is State.Running or State.Starting)
            return existing;
        temporary[t.id] = t;
        Start(t);
        return t;
    }

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
        var passwordOnly = Askpass.CanAutofill(t.hostAlias) && Askpass.PasswordOnly(t.hostAlias);
        foreach (var a in RelayaCoreMethods.TunnelSshArguments(t, passwordOnly)) info.ArgumentList.Add(a);
        // Опции «только пароль» уже в аргументах ядра — askpass нужен только для самого пароля.
        if (passwordOnly) { Askpass.SetEnvironment(info, t.hostAlias); }
        Process p;
        try { p = Process.Start(info)!; Askpass.Started(info, p); }
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
            {
                running[t.id] = (p, State.Failed, SshErrors.Describe(message, Strings.L("ssh завершился с кодом %@", p.ExitCode)));
                // Автоперезапуск (8.4, как на Mac): туннель «вместе с Relaya», который поднимался и упал, —
                // через 5, 10, 20, 40, 60… с, до 8 попыток подряд. Ручная остановка (Stop) убирает запись — и повтора нет.
                if (t.autoStart && wasUp.TryRemove(t.id, out _) || t.autoStart && retries.ContainsKey(t.id))
                {
                    var attempt = retries.AddOrUpdate(t.id, 1, (_, n) => n + 1);
                    if (attempt <= 8)
                    {
                        var delay = TimeSpan.FromSeconds(Math.Min(60, 5 * Math.Pow(2, attempt - 1)));
                        _ = System.Threading.Tasks.Task.Delay(delay).ContinueWith(task =>
                        {
                            if (running.TryGetValue(t.id, out var now) && now.Process == p && now.State == State.Failed) Start(t);
                        });
                    }
                    else retries.TryRemove(t.id, out _);
                }
            }
            Changed?.Invoke();
        };
        // ExitOnForwardFailure: если через 3 секунды ssh жив — туннель поднят.
        System.Threading.Tasks.Task.Delay(3000).ContinueWith(task =>
        {
            if (!p.HasExited && running.TryGetValue(t.id, out var cur) && cur.Process == p)
            {
                wasUp[t.id] = true;
                retries.TryRemove(t.id, out _); // поднялся — счётчик попыток с нуля
                running[t.id] = (p, State.Running, null);
                Changed?.Invoke();
            }
        });
        Changed?.Invoke();
    }

    // Для автоперезапуска: туннель хоть раз поднимался, и сколько попыток подряд уже было.
    private readonly ConcurrentDictionary<string, bool> wasUp = new();
    private readonly ConcurrentDictionary<string, int> retries = new();

    public void Stop(string id)
    {
        wasUp.TryRemove(id, out _);
        retries.TryRemove(id, out _);
        if (running.TryRemove(id, out var r) && r.Process is { HasExited: false } p)
            try { p.Kill(true); } catch (InvalidOperationException) { }
        temporary.TryRemove(id, out _);
        Changed?.Invoke();
    }

    public void StopAll()
    {
        foreach (var id in running.Keys.ToList()) Stop(id);
    }
}
