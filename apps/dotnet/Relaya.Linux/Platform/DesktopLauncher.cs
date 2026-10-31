using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Удалённые столы на Linux: RDP — FreeRDP (xfreerdp3/xfreerdp, иначе Remmina), VNC — TigerVNC vncviewer, иначе Remmina.
/// Через SSH-хост — локальный туннель, как на Windows.
internal static class DesktopLauncher
{
    public static async void Open(RemoteDesktop d, XamlRoot root)
    {
        var host = d.address;
        var port = d.port;
        string? tunnelId = null;
        if (d.viaSshHost is { Length: > 0 } via)
        {
            // Один туннель на удалённый стол: повторное открытие берёт уже работающий, закрытие клиента его гасит.
            tunnelId = "desktop:" + d.id;
            var tunnel = TunnelManager.Shared.StartTemporary(
                new Tunnel(tunnelId, L("%@ (удалённый стол)", d.name), via, TunnelKind.Local, FreePort(), d.address, d.port, false));
            var local = tunnel.listenPort;
            for (var i = 0; i < 20 && TunnelManager.Shared.StatusOf(tunnel).State == TunnelManager.State.Starting; i++) await Task.Delay(250);
            if (TunnelManager.Shared.StatusOf(tunnel) is { State: TunnelManager.State.Failed } f)
            {
                await Message(root, L("SSH-туннель: %@", f.Error ?? ""));
                return;
            }
            host = "localhost";
            port = local;
        }
        var client = d.kind == DesktopKind.Rdp ? Rdp(d, host, port) : Vnc(host, port);
        if (client == null)
        {
            await Message(root, d.kind == DesktopKind.Rdp
                ? L("Не найден RDP-клиент. Установите FreeRDP (xfreerdp) или Remmina.")
                : L("Не найден VNC-клиент. Установите TigerVNC (vncviewer) или Remmina."));
            if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
            return;
        }
        try { StopWithClient(Process.Start(client), tunnelId); }
        catch (Exception e)
        {
            await Message(root, e.Message);
            if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
        }
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

    private static void StopWithClient(Process? client, string? tunnelId)
    {
        if (client == null || tunnelId == null) return;
        client.EnableRaisingEvents = true;
        client.Exited += (_, _) => TunnelManager.Shared.Stop(tunnelId);
    }

    private static int FreePort()
    {
        var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        var port = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    public static Task Message(XamlRoot root, string text) =>
        new ContentDialog { Title = "Relaya", Content = text, CloseButtonText = "OK", XamlRoot = root }.ShowAsync().AsTask();
}
