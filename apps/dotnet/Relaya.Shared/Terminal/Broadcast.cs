using System;
using System.Collections.Generic;
using System.Linq;

namespace Relaya.Terminal;

/// Рассылка ввода во все открытые терминалы, как на Mac: набранное с клавиатуры в одном терминале уходит в остальные,
/// кроме исключённых. Не рассылаются вставки сниппетов и команд и ввод в ответ на запрос пароля (ssh, sudo, su).
internal static class Broadcast
{
    private static readonly object gate = new();
    private static readonly List<SshSession> sessions = new();
    private static readonly HashSet<SshSession> excluded = new();
    private static bool enabled;

    /// Включили, выключили, исключили терминал или открыли/закрыли сессию — обновить баннеры.
    public static event Action? Changed;

    public static bool Enabled
    {
        get { lock (gate) return enabled; }
        set
        {
            lock (gate)
            {
                if (enabled == value) return;
                enabled = value;
                if (!value) excluded.Clear();
            }
            Changed?.Invoke();
        }
    }

    /// Сколько терминалов сейчас получает ввод.
    public static int Receivers { get { lock (gate) return sessions.Count(s => !excluded.Contains(s)); } }

    public static bool Includes(SshSession s) { lock (gate) return !excluded.Contains(s); }

    public static void SetIncluded(SshSession s, bool included)
    {
        lock (gate) { if (included) excluded.Remove(s); else excluded.Add(s); }
        Changed?.Invoke();
    }

    public static void Register(SshSession s)
    {
        lock (gate) sessions.Add(s);
        Changed?.Invoke();
    }

    public static void Unregister(SshSession s)
    {
        bool off;
        lock (gate)
        {
            sessions.Remove(s);
            excluded.Remove(s);
            // Меньше двух терминалов — рассылать некуда.
            off = enabled && sessions.Count < 2;
            if (off) enabled = false;
        }
        Changed?.Invoke();
    }

    /// Ввод с клавиатуры терминала source — в остальные участвующие.
    public static void Send(SshSession source, byte[] data)
    {
        List<SshSession> targets;
        lock (gate)
        {
            if (!enabled || excluded.Contains(source)) return;
            targets = sessions.Where(s => s != source && !excluded.Contains(s)).ToList();
        }
        foreach (var t in targets) t.Receive(data);
    }
}
