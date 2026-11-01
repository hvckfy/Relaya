using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Порт сервера из вывода терминала (`localhost:3000`) — в браузере через временный туннель, как на Mac.
/// Один туннель на хост и порт: повторное открытие берёт уже работающий. Локальный порт — тот же, если свободен.
internal static class PortTunnel
{
    private static readonly Dictionary<string, Tunnel> tunnels = new();

    public static async Task OpenAsync(string alias, long port, XamlRoot root)
    {
        var key = $"port:{alias}:{port}";
        if (!tunnels.TryGetValue(key, out var tunnel))
            tunnels[key] = tunnel = new Tunnel(key, $"localhost:{port} ({alias})", alias, TunnelKind.Local, LocalPort(port), "localhost", port, false);
        if (TunnelManager.Shared.StatusOf(tunnel).State != TunnelManager.State.Running)
        {
            tunnel = TunnelManager.Shared.StartTemporary(tunnel);
            tunnels[key] = tunnel;
            for (var i = 0; i < 80 && TunnelManager.Shared.StatusOf(tunnel).State == TunnelManager.State.Starting; i++) await Task.Delay(250);
            var (state, error) = TunnelManager.Shared.StatusOf(tunnel);
            if (state != TunnelManager.State.Running)
            {
                await DesktopLauncher.Message(root, L("SSH-туннель: %@", error ?? L("SSH-туннель не поднялся за 20 секунд.")));
                return;
            }
        }
        await Windows.System.Launcher.LaunchUriAsync(new Uri($"http://localhost:{tunnel.listenPort}"));
    }

    // Тот же номер, если он свободен локально и не привилегированный; иначе любой свободный.
    private static long LocalPort(long port)
    {
        if (port >= 1024 && port <= 65535)
        {
            try
            {
                var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, (int)port);
                l.Start();
                l.Stop();
                return port;
            }
            catch (System.Net.Sockets.SocketException) { }
        }
        var any = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        any.Start();
        var free = ((System.Net.IPEndPoint)any.LocalEndpoint).Port;
        any.Stop();
        return free;
    }
}
