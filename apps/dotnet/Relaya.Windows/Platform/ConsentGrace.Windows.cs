using System;
using System.Runtime.InteropServices;

namespace Relaya.Platform;

internal static partial class ConsentGrace
{
    private const uint WmWtsSessionChange = 0x02B1;
    private const uint WmPowerBroadcast = 0x0218;
    private const int WtsSessionLock = 0x7;
    private const int WtsSessionLogoff = 0x6;
    private const int PbtApmSuspend = 0x4;

    // Делегат держим в поле: иначе сборщик мусора уберёт его, пока окно вызывает подкласс.
    private static SubclassProc? proc;

    /// Блокировка сеанса, выход и сон закрывают окно доверия: уведомления WTS и WM_POWERBROADCAST главного окна.
    public static partial void WatchSessionLock()
    {
        var hwnd = MainWindow.Hwnd;
        if (hwnd == IntPtr.Zero || proc != null) return;
        proc = (h, msg, wParam, lParam, id, data) =>
        {
            if ((msg == WmWtsSessionChange && ((int)wParam == WtsSessionLock || (int)wParam == WtsSessionLogoff))
                || (msg == WmPowerBroadcast && (int)wParam == PbtApmSuspend))
                {
                    Reset();
                    SshMux.CloseAll(); // общие соединения хостов (П-9) не переживают блокировку и сон
                }
            return DefSubclassProc(h, msg, wParam, lParam);
        };
        SetWindowSubclass(hwnd, proc, 0x5245, IntPtr.Zero);
        WTSRegisterSessionNotification(hwnd, 0 /* NOTIFY_FOR_THIS_SESSION */);
    }

    private delegate IntPtr SubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, UIntPtr id, IntPtr data);

    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id, IntPtr data);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("wtsapi32.dll")]
    private static extern bool WTSRegisterSessionNotification(IntPtr hwnd, int flags);
}
