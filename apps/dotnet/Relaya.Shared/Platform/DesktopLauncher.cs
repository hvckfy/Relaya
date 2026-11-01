using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
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

    /// Команда внешнего клиента для host:port; null — клиента нет, missing — что сказать пользователю,
    /// tempFile — временный файл клиента (.rdp), удаляется при выходе клиента (аудит Н11).
    private static partial ProcessStartInfo? Client(RemoteDesktop d, string host, long port, out string missing, out string? tempFile);

    /// Клиент запущен: приложение может вести его вывод (вопрос о сертификате, ошибки входа).
    private static partial void Started(Process client, XamlRoot root);

    /// Встроенная вкладка, если есть; иначе внешний клиент.
    public static void Open(RemoteDesktop d, XamlRoot root)
    {
        if (!OpenInTab(d)) _ = OpenExternal(d, root);
    }

    /// 9.15, как на Mac: стол в отдельном окне — своё подключение, закрытие окна его завершает.
    public static void OpenInWindow(RemoteDesktop d)
    {
        Microsoft.UI.Xaml.Controls.UserControl view;
        IDisposable owner;
        var window = new Microsoft.UI.Xaml.Window { Title = d.name };
        if (d.kind == DesktopKind.Rdp) { var r = new Desktop.RdpView(d) { HostWindow = window }; view = r; owner = r; }
        else { var v = new Desktop.VncView(d); view = v; owner = v; }
        // Тема — как у главного окна (12.1).
        if (MainWindow.Current?.Content is Microsoft.UI.Xaml.FrameworkElement main) view.RequestedTheme = main.RequestedTheme;
        window.Content = view;
        window.Closed += (_, _) => owner.Dispose();
        window.Activate();
    }

    /// Внешний клиент; исключения ловятся здесь и пишутся в трассировку — процесс не падает (аудит Н13, ревью 4).
    /// Task, а не async void: вызывающие кнопки отбрасывают результат явно.
    public static async Task OpenExternal(RemoteDesktop d, XamlRoot root)
    {
        try { await OpenExternalAsync(d, root); }
        catch (Exception e) { Trace.WriteLine($"DesktopLauncher: {e}"); }
    }

    private static async Task OpenExternalAsync(RemoteDesktop d, XamlRoot root)
    {
        var (host, port, tunnelId, error) = await Endpoint(d);
        if (error != null) { await Message(root, error); return; }
        var info = Client(d, host, port, out var missing, out var tempFile);
        if (info == null)
        {
            if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
            await Message(root, missing);
            return;
        }
        try
        {
            var client = Process.Start(info);
            StopWithClient(client, tunnelId, tempFile);
            if (client != null) Started(client, root);
        }
        catch (Exception e)
        {
            if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
            Delete(tempFile);
            await Message(root, e.Message);
        }
    }

    /// Куда подключаться: напрямую или через SSH-хост (локальный туннель `desktop:<id>`, один на стол).
    /// Ждёт, пока туннель не поднимется (Running) или не упадёт (Failed), — клиент не стартует раньше слушателя (аудит Н11).
    /// Отмена — через cancel; страховочный предел — 60 с.
    public static async Task<(string Host, long Port, string? TunnelId, string? Error)> Endpoint(RemoteDesktop d, CancellationToken cancel = default)
    {
        if (d.viaSshHost is not { Length: > 0 } via) return (d.address, d.port, null, null);
        var tunnelId = "desktop:" + d.id;
        var tunnel = TunnelManager.Shared.StartTemporary(
            new Tunnel(tunnelId, L("%@ (удалённый стол)", d.name), via, TunnelKind.Local, FreePort(), d.address, d.port, false));
        var deadline = DateTime.UtcNow.AddSeconds(60);
        while (TunnelManager.Shared.StatusOf(tunnel).State == TunnelManager.State.Starting && DateTime.UtcNow < deadline)
        {
            if (cancel.IsCancellationRequested) { TunnelManager.Shared.Stop(tunnelId); return ("", 0, null, L("Подключение отменено")); }
            await Task.Delay(250);
        }
        var status = TunnelManager.Shared.StatusOf(tunnel);
        if (status.State == TunnelManager.State.Failed)
            return ("", 0, tunnelId, L("SSH-туннель: %@", status.Error ?? ""));
        if (status.State != TunnelManager.State.Running)
            return ("", 0, tunnelId, L("SSH-туннель не поднялся за 60 секунд."));
        return ("localhost", tunnel.listenPort, tunnelId, null);
    }

    // Клиент закрыли — туннель и временный файл больше не нужны.
    private static void StopWithClient(Process? client, string? tunnelId, string? tempFile)
    {
        if (tunnelId == null && tempFile == null) return;
        if (client == null) { if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId); Delete(tempFile); return; }
        client.EnableRaisingEvents = true;
        client.Exited += (_, _) =>
        {
            if (tunnelId != null) TunnelManager.Shared.Stop(tunnelId);
            Delete(tempFile);
        };
    }

    private static void Delete(string? file)
    {
        if (file == null) return;
        try { File.Delete(file); }
        catch (Exception e) { Trace.WriteLine($"DesktopLauncher: {e.Message}"); }
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
