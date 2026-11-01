using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Значок в области уведомлений (чек-лист 8.5, 8.6, 12.5), как menu bar extra на Mac и StatusNotifierItem на Linux:
/// Shell_NotifyIcon со скрытым окном сообщений. Щелчок — окно Relaya, правый щелчок — меню туннелей, «Открыть», «Выйти».
/// Значок виден, только когда есть туннели и настройка включена.
internal static class TrayIcon
{
    private const int WM_APP_TRAY = 0x8001, WM_LBUTTONUP = 0x0202, WM_RBUTTONUP = 0x0205, WM_CONTEXTMENU = 0x007B;
    private const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4;
    private const uint MF_STRING = 0, MF_SEPARATOR = 0x800, MF_GRAYED = 1, MF_CHECKED = 8;
    private const uint TPM_RETURNCMD = 0x100, TPM_RIGHTBUTTON = 2;

    private static IntPtr hwnd;
    private static IntPtr icon;
    private static bool added;
    private static uint taskbarCreated;
    private static WndProc? proc; // держим делегат: иначе сборщик мусора уберёт его из-под окна

    public static bool Enabled => Settings.Get("tray.enabled", "1") == "1";

    /// Окно спрятано в трей (HideToTray); пропал значок — окно возвращается, иначе процесс остался бы невидимым.
    public static bool WindowHidden { get; set; }

    public static bool Visible => added;

    public static Task StartAsync()
    {
        var ui = DispatcherQueue.GetForCurrentThread();
        try
        {
            proc = WindowProc;
            var cls = new WndClass { lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc), lpszClassName = "RelayaTray", hInstance = GetModuleHandleW(null) };
            if (RegisterClassW(ref cls) == 0) throw new InvalidOperationException("RegisterClass " + Marshal.GetLastWin32Error());
            hwnd = CreateWindowExW(0, "RelayaTray", "Relaya", 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, cls.hInstance, IntPtr.Zero); // HWND_MESSAGE
            if (hwnd == IntPtr.Zero) throw new InvalidOperationException("CreateWindow " + Marshal.GetLastWin32Error());
            taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
            icon = LoadImageW(IntPtr.Zero, Path.Combine(AppContext.BaseDirectory, "Assets", "Relaya.ico"), 1, GetSystemMetrics(49), GetSystemMetrics(50), 0x10);
            TunnelManager.Shared.Changed += () => ui.TryEnqueue(Refresh);
            AppDomain.CurrentDomain.ProcessExit += (_, _) => Remove();
            Refresh();
        }
        catch (Exception e) { Terminal.TerminalView.Trace("tray: " + e.Message); }
        return Task.CompletedTask;
    }

    public static void Refresh()
    {
        var active = Enabled && (Data.AppState.Tunnels.Count > 0 || TunnelManager.Shared.Temporary.Count > 0);
        if (active && !added && hwnd != IntPtr.Zero) Add();
        else if (!active && added) Remove();
        if (!active && WindowHidden) ShowWindow();
    }

    internal static void ShowWindow()
    {
        if (MainWindow.Current is not { } w) return;
        WindowHidden = false;
        w.AppWindow.Show();
        w.Activate();
    }

    private static NotifyIconData Data_() => new()
    {
        cbSize = (uint)Marshal.SizeOf<NotifyIconData>(), hWnd = hwnd, uID = 1,
        uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP, uCallbackMessage = WM_APP_TRAY, hIcon = icon, szTip = "Relaya",
    };

    private static void Add()
    {
        var d = Data_();
        added = Shell_NotifyIconW(NIM_ADD, ref d);
    }

    private static void Remove()
    {
        if (!added) return;
        var d = Data_();
        Shell_NotifyIconW(NIM_DELETE, ref d);
        added = false;
    }

    private static IntPtr WindowProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        // Проводник перезапустился — значки пропали, ставим свой заново.
        if (msg == taskbarCreated && taskbarCreated != 0) { added = false; Refresh(); return IntPtr.Zero; }
        if (msg == WM_APP_TRAY)
        {
            var e = (int)(l.ToInt64() & 0xFFFF);
            if (e == WM_LBUTTONUP) ShowWindow();
            else if (e is WM_RBUTTONUP or WM_CONTEXTMENU) ShowMenu();
            return IntPtr.Zero;
        }
        return DefWindowProcW(h, msg, w, l);
    }

    private static void ShowMenu()
    {
        var actions = new List<Action?> { null };
        var menu = CreatePopupMenu();
        void Item(string text, Action? run, bool check = false)
        {
            AppendMenuW(menu, MF_STRING | (run == null ? MF_GRAYED : 0) | (check ? MF_CHECKED : 0), (UIntPtr)actions.Count, text);
            actions.Add(run);
        }
        void Separator() => AppendMenuW(menu, MF_SEPARATOR, UIntPtr.Zero, null);
        void Tunnels(IEnumerable<uniffi.relaya_core.Tunnel> tunnels)
        {
            foreach (var t in tunnels)
            {
                var running = TunnelManager.Shared.StatusOf(t).State is TunnelManager.State.Running or TunnelManager.State.Starting;
                Item($"{t.name} · {uniffi.relaya_core.RelayaCoreMethods.TunnelSpec(t)}",
                    () => { if (running) TunnelManager.Shared.Stop(t.id); else TunnelManager.Shared.Start(t); }, running);
            }
        }
        Item(L("Туннели"), null);
        if (Data.AppState.Tunnels.Count == 0) Item(L("Нет туннелей"), null);
        Tunnels(Data.AppState.Tunnels);
        if (TunnelManager.Shared.Temporary is { Count: > 0 } temporary)
        {
            Separator();
            Item(L("Временные"), null);
            Tunnels(temporary);
        }
        Separator();
        Item(L("Открыть Relaya"), ShowWindow);
        Item(L("Выйти из Relaya"), () =>
        {
            // Exit() может пройти без Window.Closed — туннели останавливаем сами, как stopAll на Mac.
            TunnelManager.Shared.StopAll();
            DavBridge.UnmountAll();
            Remove();
            Application.Current.Exit();
        });
        GetCursorPos(out var pt);
        SetForegroundWindow(hwnd); // иначе меню не закроется щелчком мимо
        var id = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.X, pt.Y, hwnd, IntPtr.Zero);
        DestroyMenu(menu);
        if (id > 0 && id < actions.Count) actions[id]?.Invoke();
    }

    private delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WndClass
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID, uFlags, uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    private struct Point { public int X, Y; }

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern ushort RegisterClassW(ref WndClass c);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DefWindowProcW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadImageW(IntPtr inst, string name, uint type, int cx, int cy, uint load);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr id, string? text);
    [DllImport("user32.dll")] private static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point p);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIconW(uint msg, ref NotifyIconData data);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string? name);
}
