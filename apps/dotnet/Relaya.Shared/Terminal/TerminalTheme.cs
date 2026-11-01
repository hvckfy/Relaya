using System;
using Windows.UI;

namespace Relaya.Terminal;

/// Палитра терминала. Цвет ячейки из ядра: 0 — по умолчанию, 0x01RRGGBB — RGB, 0x02_0000II — индекс 0…255.
internal sealed record TerminalTheme(Color Background, Color Foreground, Color Cursor, Color[] Ansi)
{
    public Color Selection => Color.FromArgb(90, 0x3B, 0x8E, 0xEA);

    public string Name { get; init; } = "Relaya";

    public static TerminalTheme Default => Named(CurrentName());

    /// Схема по настройкам: «следовать за темой окна» — пара светлая/тёмная, иначе одна выбранная.
    public static string CurrentName()
    {
        if (Platform.Settings.Get("terminal.followTheme", "0") != "1") return Platform.Settings.Get("terminal.theme", "Relaya");
        return WindowIsDark() ? Platform.Settings.Get("terminal.themeDark", "Campbell") : Platform.Settings.Get("terminal.themeLight", "One Half Light");
    }

    private static bool WindowIsDark() => Platform.Settings.Get("app.theme", "system") switch
    {
        "light" => false, "dark" => true,
        _ => Microsoft.UI.Xaml.Application.Current.RequestedTheme == Microsoft.UI.Xaml.ApplicationTheme.Dark,
    };

    // Схемы — общий файл resources/terminal/schemes.json (тот же список на Mac): копируется в Terminal/schemes.json
    // рядом с приложением. Нет файла — одна встроенная «Relaya».
    private static readonly Lazy<TerminalTheme[]> schemes = new(Load);

    public static string[] Names => System.Array.ConvertAll(schemes.Value, t => t.Name);

    public static bool IsDarkScheme(string name) => System.Array.Find(schemes.Value, t => t.Name == name)?.Dark ?? true;

    public bool Dark { get; init; } = true;

    public static TerminalTheme Named(string name) => System.Array.Find(schemes.Value, t => t.Name == name) ?? schemes.Value[0];

    private static TerminalTheme[] Load()
    {
        var fallback = Make("Relaya", 0x1E1E1E, 0xD4D4D4, 0xFFFFFF, "000000 CD3131 0DBC79 E5E510 2472C8 BC3FBC 11A8CD E5E5E5 666666 F14C4C 23D18B F5F543 3B8EEA D670D6 29B8DB FFFFFF");
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(System.IO.File.ReadAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "Terminal", "schemes.json")));
            var list = new System.Collections.Generic.List<TerminalTheme>();
            foreach (var e in doc.RootElement.GetProperty("schemes").EnumerateArray())
            {
                uint Hex(string s) => System.Convert.ToUInt32(s.TrimStart('#'), 16);
                var ansi = new System.Collections.Generic.List<Color>();
                foreach (var a in e.GetProperty("ansi").EnumerateArray()) ansi.Add(Rgb(Hex(a.GetString()!)));
                if (ansi.Count != 16) continue;
                list.Add(new TerminalTheme(Rgb(Hex(e.GetProperty("background").GetString()!)), Rgb(Hex(e.GetProperty("foreground").GetString()!)),
                    Rgb(Hex(e.GetProperty("cursor").GetString()!)), ansi.ToArray())
                { Name = e.GetProperty("name").GetString()!, Dark = e.GetProperty("dark").GetBoolean() });
            }
            return list.Count > 0 ? list.ToArray() : new[] { fallback };
        }
        catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException or System.Text.Json.JsonException
                                   or InvalidOperationException or FormatException or OverflowException or System.Collections.Generic.KeyNotFoundException)
        {
            TerminalView.Trace("terminal schemes: " + ex.Message);
            return new[] { fallback };
        }
    }

    private static TerminalTheme Make(string name, uint bg, uint fg, uint cursor, string ansi) =>
        new(Rgb(bg), Rgb(fg), Rgb(cursor), System.Array.ConvertAll(ansi.Split(' '), h => Rgb(System.Convert.ToUInt32(h, 16)))) { Name = name };

    public Color Resolve(uint code, bool foreground, bool bold)
    {
        switch (code >> 24)
        {
            case 1: return Rgb(code & 0xFFFFFF);
            case 2:
                var i = (int)(code & 0xFF);
                if (i < 8 && bold && foreground) i += 8;
                return Indexed(i);
            default: return foreground ? Foreground : Background;
        }
    }

    // xterm-256: 16 базовых, куб 6×6×6, 24 оттенка серого.
    private Color Indexed(int i)
    {
        if (i < 16) return Ansi[i];
        if (i < 232)
        {
            i -= 16;
            byte L(int v) => (byte)(v == 0 ? 0 : 55 + v * 40);
            return Color.FromArgb(255, L(i / 36), L(i / 6 % 6), L(i % 6));
        }
        var g = (byte)(8 + (i - 232) * 10);
        return Color.FromArgb(255, g, g, g);
    }

    private static Color Rgb(uint v) => Color.FromArgb(255, (byte)(v >> 16), (byte)(v >> 8), (byte)v);
}
