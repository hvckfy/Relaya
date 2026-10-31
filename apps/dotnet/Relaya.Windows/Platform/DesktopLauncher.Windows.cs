using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Удалённые столы на Windows: RDP — во вкладке (FreeRDP в ядре), запасной путь — mstsc с .rdp из ядра;
/// VNC — установленный VNC-клиент (TightVNC, RealVNC, UltraVNC, TigerVNC). Туннель и запуск — в Relaya.Shared.
internal static partial class DesktopLauncher
{
    private static partial bool OpenInTab(RemoteDesktop d)
    {
        if (d.kind != DesktopKind.Rdp || MainWindow.Current is not { } w) return false;
        w.OpenTab(d.name, "", new Desktop.RdpView(d), null);
        return true;
    }

    private static partial ProcessStartInfo? Client(RemoteDesktop d, string host, long port, out string missing)
    {
        missing = L("Не найден VNC-клиент. Установите TightVNC, RealVNC, UltraVNC или TigerVNC.");
        if (d.kind == DesktopKind.Rdp)
        {
            var file = Path.Combine(Path.GetTempPath(), $"relaya-{d.id}.rdp");
            File.WriteAllText(file, RelayaCoreMethods.DesktopRdpFile(d, host, port));
            return new ProcessStartInfo("mstsc.exe", $"\"{file}\"") { UseShellExecute = true };
        }
        return VncViewer() is { } viewer ? new ProcessStartInfo(viewer, $"{host}::{port}") { UseShellExecute = false } : null;
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
}
