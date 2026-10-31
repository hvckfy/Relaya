using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Удалённые столы: общий путь до сервера (напрямую или через SSH-туннель `desktop:<id>`) и запуск внешнего клиента.
/// Приложение решает только, чем открыть: встроенная вкладка (OpenInTab) и внешний клиент (Client) —
/// Relaya.Windows/Platform/DesktopLauncher.Windows.cs и Relaya.Linux/Platform/DesktopLauncher.Linux.cs (аудит А6).
internal static partial class DesktopLauncher
{
    /// Открыть во вкладке, если приложение умеет (RDP через ядро); false — внешний клиент.
    private static partial bool OpenInTab(RemoteDesktop d);

    /// Команда внешнего клиента для host:port; null — клиента нет, missing — что сказать пользователю.
    private static partial ProcessStartInfo? Client(RemoteDesktop d, string host, long port, out string missing);

    /// Встроенная вкладка, если есть; иначе внешний клиент.
    public static void Open(RemoteDesktop d, XamlRoot root)
    {
        if (!OpenInTab(d)) OpenExternal(d, root);
    }

    /// Обработчик кнопки: исключение не должно валить процесс (аудит Н13).
    public static async void OpenExternal(RemoteDesktop d, XamlRoot root)
    {
        try { await OpenExternalAsync(d, root); }
        catch (Exception e) { Trace.WriteLine($"DesktopLauncher: {e}"); }
    }

    private static async Task OpenExternalAsync(RemoteDesktop d, XamlRoot root)
    {
        var (host, port, tunnelId, error) = await Endpoint(d);
        if (error != null) { await Message(root, error); return; }
        var info = Client(d, host, port, out var missing);
        if (info == null)
        {
            if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
            await Message(root, missing);
            return;
        }
        try { StopWithClient(Process.Start(info), tunnelId); }
        catch (Exception e)
        {
            if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
            await Message(root, e.Message);
        }
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

    // Клиент закрыли — туннель больше не нужен.
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
