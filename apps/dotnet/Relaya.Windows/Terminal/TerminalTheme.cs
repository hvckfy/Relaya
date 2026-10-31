using System;
using Windows.UI;

namespace Relaya.Terminal;

/// Палитра терминала. Цвет ячейки из ядра: 0 — по умолчанию, 0x01RRGGBB — RGB, 0x02_0000II — индекс 0…255.
internal sealed record TerminalTheme(Color Background, Color Foreground, Color Cursor, Color[] Ansi)
{
    public Color Selection => Color.FromArgb(90, 0x3B, 0x8E, 0xEA);

    public string Name { get; init; } = "Relaya";

    public static TerminalTheme Default => Named(Platform.Settings.Get("terminal.theme", "Relaya"));

    public static readonly string[] Names = { "Relaya", "Light", "Solarized Dark", "Dracula", "Nord", "One Dark" };

    public static TerminalTheme Named(string name) => name switch
    {
        "Light" => Make(name, 0xFFFFFF, 0x1F1F1F, 0x1F1F1F, "000000 C91B00 00A600 C7C400 0225C7 CA30C7 00A6B2 BFBFBF 686868 FF6E67 5FF967 B8B200 6871FF FF77FF 5FFDFF FFFFFF"),
        "Solarized Dark" => Make(name, 0x002B36, 0x839496, 0x93A1A1, "073642 DC322F 859900 B58900 268BD2 D33682 2AA198 EEE8D5 002B36 CB4B16 586E75 657B83 839496 6C71C4 93A1A1 FDF6E3"),
        "Dracula" => Make(name, 0x282A36, 0xF8F8F2, 0xF8F8F2, "21222C FF5555 50FA7B F1FA8C BD93F9 FF79C6 8BE9FD F8F8F2 6272A4 FF6E6E 69FF94 FFFFA5 D6ACFF FF92DF A4FFFF FFFFFF"),
        "Nord" => Make(name, 0x2E3440, 0xD8DEE9, 0xD8DEE9, "3B4252 BF616A A3BE8C EBCB8B 81A1C1 B48EAD 88C0D0 E5E9F0 4C566A BF616A A3BE8C EBCB8B 81A1C1 B48EAD 8FBCBB ECEFF4"),
        "One Dark" => Make(name, 0x282C34, 0xABB2BF, 0x528BFF, "282C34 E06C75 98C379 E5C07B 61AFEF C678DD 56B6C2 ABB2BF 5C6370 E06C75 98C379 E5C07B 61AFEF C678DD 56B6C2 FFFFFF"),
        _ => Make("Relaya", 0x1E1E1E, 0xD4D4D4, 0xFFFFFF, "000000 CD3131 0DBC79 E5E510 2472C8 BC3FBC 11A8CD E5E5E5 666666 F14C4C 23D18B F5F543 3B8EEA D670D6 29B8DB FFFFFF"),
    };

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
