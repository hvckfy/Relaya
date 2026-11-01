using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Windows.UI;

namespace Relaya.Platform;

/// «Как в системе» на Linux: Uno системный акцент не отдаёт — читаем его сами. GNOME 47+ — gsettings
/// org.gnome.desktop.interface accent-color (имя из палитры GNOME); KDE Plasma — AccentColor в ~/.config/kdeglobals.
/// Не нашли — акцент Uno по умолчанию.
internal static partial class Accent
{
    // Палитра акцентов GNOME 47 (libadwaita).
    private static readonly (string Name, uint Rgb)[] Gnome =
    {
        ("blue", 0x3584E4), ("teal", 0x2190A4), ("green", 0x3A944A), ("yellow", 0xC88800), ("orange", 0xED5B00),
        ("red", 0xE62D42), ("pink", 0xD56199), ("purple", 0x9141AC), ("slate", 0x6F8396),
    };

    private static partial Color? PlatformSystemAccent() => Kde() ?? GnomeAccent();

    private static Color? Kde()
    {
        var config = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is { Length: > 0 } x
            ? x : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var file = Path.Combine(config, "kdeglobals");
        try
        {
            if (!File.Exists(file)) return null;
            var line = File.ReadLines(file).FirstOrDefault(l => l.StartsWith("AccentColor=", StringComparison.Ordinal));
            var parts = line?["AccentColor=".Length..].Split(',');
            if (parts is not { Length: >= 3 } || !byte.TryParse(parts[0], out var r) || !byte.TryParse(parts[1], out var g) || !byte.TryParse(parts[2], out var b)) return null;
            return Color.FromArgb(255, r, g, b);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Terminal.TerminalView.Trace("accent kde: " + e.Message);
            return null;
        }
    }

    private static Color? GnomeAccent()
    {
        if (Dialogs.Which("gsettings") is not { } gsettings) return null;
        var info = new ProcessStartInfo(gsettings) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "get", "org.gnome.desktop.interface", "accent-color" }) info.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(info)!;
            // Зависший gsettings (мёртвый dconf или D-Bus) не держит окно: читаем асинхронно и ждём не дольше 2 с.
            var read = p.StandardOutput.ReadToEndAsync();
            if (!read.Wait(2000) || !p.WaitForExit(500))
            {
                try { p.Kill(true); } catch (InvalidOperationException) { } // уже вышел
                return null;
            }
            if (p.ExitCode != 0) return null; // старый GNOME: ключа нет
            var name = read.Result.Trim().Trim('\'');
            return Gnome.FirstOrDefault(c => c.Name == name) is { Name: not null } hit ? FromRgb(hit.Rgb) : null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException or AggregateException)
        {
            Terminal.TerminalView.Trace("accent gnome: " + e.Message);
            return null;
        }
    }
}
