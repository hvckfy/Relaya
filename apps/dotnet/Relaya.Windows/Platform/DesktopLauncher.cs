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

/// Удалённые столы на Windows: RDP — встроенный «Подключение к удалённому рабочему столу» (mstsc) с .rdp из ядра,
/// VNC — установленный VNC-клиент (TightVNC, RealVNC, UltraVNC, TigerVNC). Через SSH-хост — локальный туннель.
internal static class DesktopLauncher
{
    /// RDP — во вкладке (FreeRDP в ядре); VNC — внешний клиент.
    public static void Open(RemoteDesktop d, XamlRoot root)
    {
        if (d.kind == DesktopKind.Rdp && MainWindow.Current is { } w) { w.OpenTab(d.name, "\ue7f4", new Desktop.RdpView(d), null); return; }
        OpenExternal(d, root);
    }

    /// Куда подключаться: напрямую или через SSH-хост (локальный туннель `desktop:<id>`, один на стол).
    public static async Task<(string Host, long Port, string? TunnelId, string? Error)> Endpoint(RemoteDesktop d)
    {
        if (d.viaSshHost is not { Length: > 0 } via) return (d.address, d.port, null, null);
        var tunnelId = "desktop:" + d.id;
        var tunnel = TunnelManager.Shared.StartTemporary(
            new Tunnel(tunnelId, L("%@ (удалённый стол)", d.name), via, TunnelKind.Local, FreePort(), d.address, d.port, false));
        for (var i = 0; i < 20 && TunnelManager.Shared.StatusOf(tunnel).State == TunnelManager.State.Starting; i++) await Task.Delay(250);
        if (TunnelManager.Shared.StatusOf(tunnel) is { State: TunnelManager.State.Failed } f)
            return ("", 0, tunnelId, L("SSH-туннель: %@", f.Error ?? ""));
        return ("localhost", tunnel.listenPort, tunnelId, null);
    }

    /// Запасной путь: mstsc с .rdp из ядра или установленный VNC-клиент.
    public static async void OpenExternal(RemoteDesktop d, XamlRoot root)
    {
        var (host, port, tunnelId, error) = await Endpoint(d);
        if (error != null) { await Message(root, error); return; }
        if (d.kind == DesktopKind.Rdp)
        {
            var file = Path.Combine(Path.GetTempPath(), $"relaya-{d.id}.rdp");
            File.WriteAllText(file, RelayaCoreMethods.DesktopRdpFile(d, host, port));
            StopWithClient(Process.Start(new ProcessStartInfo("mstsc.exe", $"\"{file}\"") { UseShellExecute = true }), tunnelId);
            return;
        }
        var viewer = VncViewer();
        if (viewer == null)
        {
            await Message(root, L("Не найден VNC-клиент. Установите TightVNC, RealVNC, UltraVNC или TigerVNC."));
            if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
            return;
        }
        StopWithClient(Process.Start(new ProcessStartInfo(viewer, $"{host}::{port}") { UseShellExecute = false }), tunnelId);
    }

    private static void StopWithClient(Process? client, string? tunnelId)
    {
        if (client == null || tunnelId == null) return;
        client.EnableRaisingEvents = true;
        client.Exited += (_, _) => TunnelManager.Shared.Stop(tunnelId);
    }

    private static string? VncViewer()
    {
        var pf = new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) };
        var candidates = new[]
        {
            @"TightVNC\tvnviewer.exe", @"RealVNC\VNC Viewer\vncviewer.exe", @"uvnc bvba\UltraVNC\vncviewer.exe",
            @"UltraVNC\vncviewer.exe", @"TigerVNC\vncviewer.exe",
        };
        return pf.SelectMany(p => candidates.Select(c => Path.Combine(p, c))).FirstOrDefault(File.Exists);
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
