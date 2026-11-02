using System.Diagnostics;
using System.IO;
using uniffi.relaya_core;

namespace Relaya.Platform;

/// <summary>
/// <c>--demo</c>: fictional hosts and keys in a temporary folder instead of <c>~/.ssh</c> and the Relaya folder, for
/// README screenshots and presentations. The user's real files and credentials are never read or written.
/// </summary>
internal static class Demo
{
    /// <summary>The demo folder, or null when the app runs on the user's own data.</summary>
    public static string? Root { get; private set; }

    /// <summary>Where <c>--screenshots &lt;dir&gt;</c> saves the scenes; null without it.</summary>
    public static string? ScreenshotDir { get; private set; }

    /// <summary>Reads <c>--demo</c> and <c>--screenshots</c>; must run before anything touches <c>AppState</c> paths.</summary>
    public static void Configure(string[] args)
    {
        if (System.Array.IndexOf(args, "--demo") < 0) return;
        Root = Prepare();
        var i = System.Array.IndexOf(args, "--screenshots");
        if (i >= 0 && i + 1 < args.Length) ScreenshotDir = Path.GetFullPath(args[i + 1]);
    }

    private static string Prepare()
    {
        var root = Path.Combine(Path.GetTempPath(), "relaya-demo");
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        var ssh = Path.Combine(root, "ssh");
        Directory.CreateDirectory(ssh);
        Directory.CreateDirectory(Path.Combine(root, "support"));
        // The same fictional hosts as on the Mac, from the core.
        File.WriteAllText(Path.Combine(ssh, "config"), RelayaCoreMethods.DemoSshConfig());
        foreach (var (name, comment) in new[] { ("id_ed25519", "alex@laptop"), ("id_ed25519_work", "alex@acme · deploy"), ("id_ed25519_homelab", "alex@laptop · homelab") })
        {
            var info = new ProcessStartInfo(System.OperatingSystem.IsWindows() ? "ssh-keygen.exe" : "ssh-keygen") { UseShellExecute = false };
            foreach (var a in new[] { "-t", "ed25519", "-N", "", "-q", "-C", comment, "-f", Path.Combine(ssh, name) }) info.ArgumentList.Add(a);
            using var p = Process.Start(info);
            p?.WaitForExit();
        }
        return root;
    }
}
