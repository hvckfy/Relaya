using Windows.UI;

namespace Relaya.Terminal;

/// Палитра терминала. Цвет ячейки из ядра: 0 — по умолчанию, 0x01RRGGBB — RGB, 0x02_0000II — индекс 0…255.
internal sealed record TerminalTheme(Color Background, Color Foreground, Color Cursor, Color[] Ansi)
{
    public static TerminalTheme Default { get; } = new(
        Rgb(0x1E1E1E), Rgb(0xD4D4D4), Rgb(0xFFFFFF),
        new[]
        {
            Rgb(0x000000), Rgb(0xCD3131), Rgb(0x0DBC79), Rgb(0xE5E510), Rgb(0x2472C8), Rgb(0xBC3FBC), Rgb(0x11A8CD), Rgb(0xE5E5E5),
            Rgb(0x666666), Rgb(0xF14C4C), Rgb(0x23D18B), Rgb(0xF5F543), Rgb(0x3B8EEA), Rgb(0xD670D6), Rgb(0x29B8DB), Rgb(0xFFFFFF),
        });

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
