using System.IO;
using System.Threading.Tasks;
using Windows.Graphics;

namespace Relaya.Platform;

/// <summary>
/// <c>--demo --screenshots &lt;dir&gt;</c>: shows each README scene on the demo data and hands it to CI to capture.
/// </summary>
/// <remarks>
/// The capture tool is outside the app (PowerShell on Windows, ImageMagick under Xvfb on Linux): for each scene the
/// app writes <c>&lt;os&gt;-&lt;scene&gt;.ready</c> with the window rectangle "x y width height" and waits for
/// <c>&lt;os&gt;-&lt;scene&gt;.png</c>; at the end it writes <c>done</c> and quits. A missing capture writes
/// <c>failed</c> so CI stops with a reason.
/// </remarks>
internal static class DemoScreenshots
{
    /// <summary>Runs the scenes; any error ends the run with a <c>failed</c> marker that names it (E-3).</summary>
    public static async Task RunAsync(MainWindow window, string dir)
    {
        try { await RunScenesAsync(window, dir); }
        catch (System.Exception e)
        {
            System.Console.Error.WriteLine($"screenshots: {e}");
            File.WriteAllText(Path.Combine(dir, "failed"), e.Message);
            Microsoft.UI.Xaml.Application.Current.Exit();
        }
    }

    private static async Task RunScenesAsync(MainWindow window, string dir)
    {
        Directory.CreateDirectory(dir);
        var os = System.OperatingSystem.IsWindows() ? "windows" : "linux";
        // Hosted Windows runners have a 1024x768 screen with a taskbar at the bottom: the window, invisible borders
        // included, must stay clear of both to be captured clean (E-8).
        window.AppWindow.MoveAndResize(new RectInt32 { X = 0, Y = 0, Width = 1000, Height = 700 });
        var scenes = new (string Name, System.Action Show)[]
        {
            ("hosts", window.ShowNothing),
            // No host card yet: it probes the fictional hosts over ssh and would show connection errors.
            ("keys", () => window.ShowPage(new Pages.KeysPage())),
            ("snippets", () => window.ShowPage(new Pages.SnippetsPage())),
            ("tunnels", () => window.ShowPage(new Pages.TunnelsPage())),
            ("agents", () => window.ShowPage(new Pages.AgentsPage())),
            ("settings", () => window.ShowPage(new Pages.SettingsPage())),
        };
        foreach (var (name, show) in scenes)
        {
            System.Console.Error.WriteLine($"screenshots: {name}");
            show();
            await Task.Delay(2000);
            var p = window.AppWindow.Position;
            var s = window.AppWindow.Size;
            var png = Path.Combine(dir, $"{os}-{name}.png");
            File.Delete(png);
            File.WriteAllText(Path.Combine(dir, $"{os}-{name}.ready"), $"{p.X} {p.Y} {s.Width} {s.Height}\n");
            var waited = 0;
            while (!File.Exists(png) && waited < 60_000) { await Task.Delay(250); waited += 250; }
            if (!File.Exists(png))
            {
                File.WriteAllText(Path.Combine(dir, "failed"), $"no capture for {name}");
                break;
            }
        }
        File.WriteAllText(Path.Combine(dir, "done"), "");
        Microsoft.UI.Xaml.Application.Current.Exit();
    }
}
