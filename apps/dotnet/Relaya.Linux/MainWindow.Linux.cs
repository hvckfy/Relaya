using System.Linq;
using Relaya.Platform;

namespace Relaya;

public sealed partial class MainWindow
{
    // Значок виден и хоть один туннель работает — окно прячется, туннели живут; вернуть — щелчок по значку.
    private partial bool HideToTray()
    {
        if (!TrayIcon.Visible) return false;
        var tunnels = Data.AppState.Tunnels.Concat(TunnelManager.Shared.Temporary);
        if (!tunnels.Any(t => TunnelManager.Shared.StatusOf(t).State is TunnelManager.State.Running or TunnelManager.State.Starting)) return false;
        AppWindow.Hide();
        TrayIcon.WindowHidden = true;
        return true;
    }
}
