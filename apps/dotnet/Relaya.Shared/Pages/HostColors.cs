using System.Collections.Generic;
using Windows.UI;
using static Relaya.Strings;

namespace Relaya.Pages;

/// «Цвет хоста» (Е.10): та же палитра, что на Mac (Theme.hostColors) — точка в боковой панели и цвет иконки вкладки.
internal static class HostColors
{
    public static readonly (string Name, string Label, Color Color)[] All =
    {
        ("blue", L("Синий"), Color.FromArgb(255, 0x0A, 0x7A, 0xFF)),
        ("orange", L("Оранжевый"), Color.FromArgb(255, 0xF0, 0x8A, 0x00)),
        ("purple", L("Фиолетовый"), Color.FromArgb(255, 0x8E, 0x4E, 0xC6)),
        ("gray", L("Серый"), Color.FromArgb(255, 0x8E, 0x8E, 0x93)),
    };

    public static Color? Of(string? name)
    {
        foreach (var c in All) if (c.Name == name) return c.Color;
        return null;
    }
}
