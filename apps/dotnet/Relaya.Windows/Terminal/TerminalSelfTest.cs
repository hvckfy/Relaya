using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;

namespace Relaya.Terminal;

/// `Relaya.exe --selftest-terminal <log>`: настоящий TerminalView (WinUI + Win2D) в окне; байты подаются из фонового
/// потока, как из ConPTY, и проверяется, что кадр с этим текстом действительно отрисован. Для CI.
internal static class TerminalSelfTest
{
    public static string? LogPath;

    public static void Run(Window window)
    {
        var view = new TerminalView();
        window.Content = view;
        window.Activate();
        var log = new StringBuilder();
        view.Loaded += async (_, _) =>
        {
            log.AppendLine($"loaded {view.ActualWidth}x{view.ActualHeight}");
            // Из фонового потока — как PseudoConsole.ReadLoop.
            await Task.Run(() => view.Feed(Encoding.UTF8.GetBytes("\x1b[2J\x1b[Hrelaya-selftest-line\r\nsecond line\r\n")));
            var ok = false;
            for (var i = 0; i < 100 && !ok; i++)
            {
                await Task.Delay(100);
                ok = view.DrawnText;
            }
            var screen = view.Emulator.ScreenText().FirstOrDefault(l => l.Trim().Length > 0)?.Trim() ?? "";
            log.AppendLine($"emulator first line: {screen}");
            log.AppendLine($"drawn text: {view.DrawnText}, draw error: {view.DrawError ?? "none"}");
            var pass = ok && view.DrawError == null && screen == "relaya-selftest-line";
            log.AppendLine(pass ? "selftest: OK" : "selftest: FAIL");
            try { File.WriteAllText(LogPath ?? "selftest.log", log.ToString()); } catch (Exception) { }
            Environment.Exit(pass ? 0 : 1);
        };
    }
}
