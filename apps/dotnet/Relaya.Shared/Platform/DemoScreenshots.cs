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
    public static async Task RunAsync(MainWindow window, string dir)
    {
        Directory.CreateDirectory(dir);
        var os = OperatingSystem.IsWindows() ? "windows" : "linux";
        window.AppWindow.MoveAndResize(new RectInt32(80, 80, 1280, 800));
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
            show();
            await Task.Delay(2000);
            var p = window.AppWindow.Position;
            var s = window.AppWindow.Size;
            var png = Path.Combine(dir, $"{os}-{name}.png");
            File.Delete(png);
            File.WriteAllText(Path.Combine(dir, $"{os}-{name}.ready"), $"{p.X} {p.Y} {s.Width} {s.Height}");
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
