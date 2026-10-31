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
    public static async void Open(RemoteDesktop d, XamlRoot root)
    {
        var host = d.address;
        var port = d.port;
        if (d.viaSshHost is { Length: > 0 } via)
        {
            var local = FreePort();
            var tunnel = new Tunnel(RelayaCoreMethods.CoreNewId(), $"{d.name} (desktop)", via, TunnelKind.Local, local, d.address, d.port, false);
            TunnelManager.Shared.Start(tunnel);
            for (var i = 0; i < 20 && TunnelManager.Shared.StatusOf(tunnel).State == TunnelManager.State.Starting; i++) await Task.Delay(250);
            if (TunnelManager.Shared.StatusOf(tunnel) is { State: TunnelManager.State.Failed } f)
            {
                await Message(root, L("SSH-туннель: %@", f.Error ?? ""));
                return;
            }
            host = "localhost";
            port = local;
        }
        if (d.kind == DesktopKind.Rdp)
        {
            var file = Path.Combine(Path.GetTempPath(), $"relaya-{d.id}.rdp");
            File.WriteAllText(file, RelayaCoreMethods.DesktopRdpFile(d, host, port));
            Process.Start(new ProcessStartInfo("mstsc.exe", $"\"{file}\"") { UseShellExecute = true });
            return;
        }
        var viewer = VncViewer();
        if (viewer == null)
        {
            await Message(root, L("Не найден VNC-клиент. Установите TightVNC, RealVNC, UltraVNC или TigerVNC."));
            return;
        }
        Process.Start(new ProcessStartInfo(viewer, $"{host}::{port}") { UseShellExecute = false });
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
