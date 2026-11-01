using System;

namespace Relaya.Platform;

/// «Не спрашивать повторно N минут» после подтверждения сохранённого пароля (чек-лист 12.4, как окно Touch ID на Mac):
/// одно подтверждение покрывает следующие запросы askpass, пока не истёк срок. 0 — спрашивать каждый раз.
internal static partial class ConsentGrace
{
    public const string Key = "security.confirmGraceMinutes";
    private static readonly object Gate = new();
    private static DateTime until = DateTime.MinValue;

    /// Подтвердить через `ask`, если окно доверия закрыто; успешное подтверждение открывает его на N минут.
    public static bool Confirm(Func<bool> ask)
    {
        var minutes = int.TryParse(Settings.GetFresh(Key, "0"), out var m) ? Math.Clamp(m, 0, 60) : 0;
        lock (Gate)
        {
            if (minutes > 0 && DateTime.UtcNow < until) return true;
        }
        if (!ask()) return false;
        lock (Gate) until = minutes > 0 ? DateTime.UtcNow.AddMinutes(minutes) : DateTime.MinValue;
        return true;
    }

    /// Платформа сбрасывает окно доверия при блокировке сеанса и сне (как SecretGate на Mac, S6).
    public static partial void WatchSessionLock();

    /// Сбросить окно доверия (блокировка сеанса, выход).
    public static void Reset()
    {
        lock (Gate) until = DateTime.MinValue;
    }
}
