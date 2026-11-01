using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Удалённые столы на Linux: RDP — во вкладке (IronRDP в ядре), запасной путь — FreeRDP (xfreerdp3/xfreerdp) или Remmina;
/// VNC — TigerVNC vncviewer, иначе Remmina. Туннель и запуск — в Relaya.Shared.
internal static partial class DesktopLauncher
{
    private static partial bool OpenInTab(RemoteDesktop d)
    {
        if (d.kind != DesktopKind.Rdp || MainWindow.Current is not { } w) return false;
        w.OpenTab(d.name, "\ue7f4", new Desktop.RdpView(d), null);
        return true;
    }

    private static partial ProcessStartInfo? Client(RemoteDesktop d, string host, long port, out string missing, out string? tempFile)
    {
        tempFile = null;
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
            // Вывод и ввод — через Relaya (Л6): из меню у xfreerdp нет терминала, и вопрос о сертификате повис бы.
            var info = new ProcessStartInfo(freerdp)
            {
                UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            };
            info.ArgumentList.Add($"/v:{host}:{port}");
            if (d.user.Length > 0) info.ArgumentList.Add("/u:" + d.user);
            info.ArgumentList.Add(d.fullScreen ? "/f" : "/dynamic-resolution");
            info.ArgumentList.Add("+clipboard");
            return info;
        }
        return Remmina($"rdp://{(d.user.Length > 0 ? Uri.EscapeDataString(d.user) + "@" : "")}{host}:{port}");
    }

    // --- xfreerdp: вопрос о сертификате — диалогом, как у встроенного RDP; ошибки — понятным текстом ---

    private const string TrustQuestion = "Do you trust the above certificate?";

    private static partial void Started(Process client, XamlRoot root)
    {
        if (!client.StartInfo.RedirectStandardOutput) return;
        var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var log = new StringBuilder();
        var gate = new object();
        // xfreerdp переспрашивает несколько раз подряд: пока диалог открыт, новые вопросы не показываем (ревью 2).
        var asking = 0;
        async Task Pump(StreamReader reader)
        {
            var buf = new char[4096];
            int n;
            while ((n = await reader.ReadAsync(buf, 0, buf.Length)) > 0)
            {
                string text;
                lock (gate)
                {
                    log.Append(buf, 0, n);
                    if (log.Length > 16384) log.Remove(0, log.Length - 16384);
                    text = log.ToString();
                }
                // Вопрос печатается без перевода строки — ищем его в накопленном выводе, а не построчно.
                var at = text.LastIndexOf(TrustQuestion, StringComparison.Ordinal);
                if (at < 0) continue;
                var block = text[..at];
                lock (gate) log.Clear();
                if (System.Threading.Interlocked.Exchange(ref asking, 1) == 1) continue;
                ui.TryEnqueue(async () =>
                {
                    try { await AskCertAsync(client, block, root); }
                    finally { System.Threading.Volatile.Write(ref asking, 0); }
                });
            }
        }
        _ = Pump(client.StandardOutput);
        _ = Pump(client.StandardError);
        client.EnableRaisingEvents = true;
        client.Exited += (_, _) =>
        {
            string tail;
            lock (gate) tail = log.ToString();
            // В журнал — только хвост: в полном выводе детали сертификата, адрес и имя пользователя (ревью 5).
            Trace.WriteLine($"xfreerdp: exit {client.ExitCode}: " + Last(tail, 600));
            if (client.ExitCode == 0 || tail.Trim().Length == 0) return;
            var explained = RelayaCoreMethods.RemoteExplain(RemoteProtocol.Rdp, tail);
            ui.TryEnqueue(() => _ = Message(root, explained is { } p ? L(p.title) + "\n\n" + L(p.hint) : Last(tail, 600)));
        };
    }

    private static string Last(string text, int max) => text.Length <= max ? text.Trim() : "…" + text[^max..].Trim();

    // Блок «Certificate details …» xfreerdp: отпечаток, имя, издатель; «has changed» — сертификат сменился.
    private static async Task AskCertAsync(Process client, string block, XamlRoot root)
    {
        var start = block.LastIndexOf("Certificate details", StringComparison.OrdinalIgnoreCase);
        var details = (start >= 0 ? block[start..] : Last(block, 1200)).Trim();
        var changed = block.Contains("has changed", StringComparison.OrdinalIgnoreCase)
            || block.Contains("does not match", StringComparison.OrdinalIgnoreCase);
        var content = new StackPanel { Spacing = 8 };
        if (changed)
            content.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Warning, IsOpen = true, IsClosable = false,
                Title = L("Отпечаток изменился"), Message = L("Раньше у этого сервера был другой сертификат. Убедитесь, что подключаетесь к нужному серверу."),
            });
        content.Children.Add(new TextBlock
        {
            Text = details, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily(Terminal.TerminalView.ResolvedMonospace),
        });
        var dialog = new ContentDialog
        {
            Title = L("Проверьте сертификат сервера"), Content = new ScrollViewer { Content = content, MaxHeight = 420 },
            PrimaryButtonText = L("Доверять"), SecondaryButtonText = L("Только сейчас"), CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Close, XamlRoot = root,
        };
        // Уже открыт другой диалог Relaya — ждём его, а не отвечаем за пользователя (ревью 2). xfreerdp ждёт ответа в stdin.
        string? answer = null;
        for (var attempt = 0; answer == null && attempt < 120 && !client.HasExited; attempt++)
        {
            try
            {
                answer = await dialog.ShowAsync() switch
                {
                    ContentDialogResult.Primary => "Y",
                    ContentDialogResult.Secondary => "T",
                    _ => "N",
                };
            }
            catch (Exception) { await Task.Delay(1000); }
        }
        if (answer == null) return;
        try
        {
            if (client.HasExited) return;
            await client.StandardInput.WriteLineAsync(answer);
            await client.StandardInput.FlushAsync();
        }
        catch (Exception e) { Trace.WriteLine("xfreerdp stdin: " + e.Message); }
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
