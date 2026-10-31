using System;
using System.Diagnostics;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Удалённые столы на Linux: RDP — FreeRDP (xfreerdp3/xfreerdp), иначе Remmina; VNC — TigerVNC vncviewer, иначе Remmina.
/// Встроенной вкладки пока нет. Туннель и запуск — в Relaya.Shared.
internal static partial class DesktopLauncher
{
    private static partial bool OpenInTab(RemoteDesktop d) => false;

    private static partial ProcessStartInfo? Client(RemoteDesktop d, string host, long port, out string missing)
    {
        if (d.kind == DesktopKind.Rdp)
        {
            missing = L("Не найден RDP-клиент. Установите FreeRDP (xfreerdp) или Remmina.");
            return Rdp(d, host, port);
        }
        missing = L("Не найден VNC-клиент. Установите TigerVNC (vncviewer) или Remmina.");
        return Vnc(host, port);
    }

    private static ProcessStartInfo? Rdp(RemoteDesktop d, string host, long port)
    {
        if ((Dialogs.Which("xfreerdp3") ?? Dialogs.Which("xfreerdp")) is { } freerdp)
        {
            var info = new ProcessStartInfo(freerdp) { UseShellExecute = false };
            info.ArgumentList.Add($"/v:{host}:{port}");
            if (d.user.Length > 0) info.ArgumentList.Add("/u:" + d.user);
            info.ArgumentList.Add(d.fullScreen ? "/f" : "/dynamic-resolution");
            info.ArgumentList.Add("+clipboard");
            return info;
        }
        return Remmina($"rdp://{(d.user.Length > 0 ? Uri.EscapeDataString(d.user) + "@" : "")}{host}:{port}");
    }

    private static ProcessStartInfo? Vnc(string host, long port)
    {
        if (Dialogs.Which("vncviewer") is { } viewer)
        {
            var info = new ProcessStartInfo(viewer) { UseShellExecute = false };
            info.ArgumentList.Add($"{host}::{port}");
            return info;
        }
        return Remmina($"vnc://{host}:{port}");
    }

    private static ProcessStartInfo? Remmina(string url)
    {
        if (Dialogs.Which("remmina") is not { } remmina) return null;
        var info = new ProcessStartInfo(remmina) { UseShellExecute = false };
        info.ArgumentList.Add("-c");
        info.ArgumentList.Add(url);
        return info;
    }
}
