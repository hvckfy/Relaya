using System;
using System.Globalization;
using Microsoft.UI.Xaml;
using Windows.UI;

namespace Relaya.Platform;

/// Цвет акцента (как «Персонализация → Цвета» в Windows): «Как в системе» или свой — из палитры Windows или любой.
/// Свой цвет переопределяет SystemAccentColor и оттенки Light1–3/Dark1–3 в ресурсах приложения; системные настройки
/// не меняются. «Как в системе» на Windows — акцент WinUI по умолчанию (системный), на Linux — акцент GNOME/KDE,
/// если его удаётся прочитать (PlatformSystemAccent).
internal static partial class Accent
{
    public const string SettingKey = "app.accent";

    /// 48 цветов палитры «Цвета» Параметров Windows, по строкам как там.
    public static readonly uint[] Palette =
    {
        0xFFB900, 0xFF8C00, 0xF7630C, 0xCA5010, 0xDA3B01, 0xEF6950, 0xD13438, 0xFF4343,
        0xE74856, 0xE81123, 0xEA005E, 0xC30052, 0xE3008C, 0xBF0077, 0xC239B3, 0x9A0089,
        0x0078D4, 0x0063B1, 0x8E8CD8, 0x6B69D6, 0x8764B8, 0x744DA9, 0xB146C2, 0x881798,
        0x0099BC, 0x2D7D9A, 0x00B7C3, 0x038387, 0x00B294, 0x018574, 0x00CC6A, 0x10893E,
        0x7A7574, 0x5D5A58, 0x68768A, 0x515C6B, 0x567C73, 0x486860, 0x498205, 0x107C10,
        0x767676, 0x4C4A48, 0x69797E, 0x4A5459, 0x647C64, 0x525E54, 0x847545, 0x7E735F,
    };

    private static readonly string[] Keys =
    {
        "SystemAccentColor", "SystemAccentColorLight1", "SystemAccentColorLight2", "SystemAccentColorLight3",
        "SystemAccentColorDark1", "SystemAccentColorDark2", "SystemAccentColorDark3",
    };

    /// Свой цвет или null — «Как в системе».
    public static Color? Custom
    {
        get => Parse(Settings.Get(SettingKey, ""));
        set => Settings.Set(SettingKey, value is { } c ? $"#{c.R:X2}{c.G:X2}{c.B:X2}" : "");
    }

    public static Color FromRgb(uint v) => Color.FromArgb(255, (byte)(v >> 16), (byte)(v >> 8), (byte)v);

    /// Поставить акцент в ресурсы приложения. Вызывается из MainWindow.ApplyTheme; кисти перечитываются там же сменой темы.
    public static void Apply()
    {
        var resources = Application.Current.Resources;
        if ((Custom ?? PlatformSystemAccent()) is not { } accent)
        {
            foreach (var k in Keys) resources.Remove(k); // системный акцент WinUI
            return;
        }
        var shades = new[] { 0.0, 0.12, 0.24, 0.36, -0.10, -0.20, -0.30 };
        for (var i = 0; i < Keys.Length; i++) resources[Keys[i]] = Shade(accent, shades[i]);
    }

    /// Акцент системы, если WinUI сам его не берёт (Linux: GNOME/KDE); null — оставить по умолчанию.
    private static partial Color? PlatformSystemAccent();

    private static Color? Parse(string s) =>
        s.Length == 7 && s[0] == '#' && uint.TryParse(s.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v) ? FromRgb(v) : null;

    // Оттенок по светлоте HSL, как у системных Light1–3/Dark1–3: тон и насыщенность те же.
    private static Color Shade(Color c, double delta)
    {
        double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), l = (max + min) / 2, h = 0, s = 0;
        if (max != min)
        {
            var d = max - min;
            s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            h = max == r ? (g - b) / d + (g < b ? 6 : 0) : max == g ? (b - r) / d + 2 : (r - g) / d + 4;
            h /= 6;
        }
        l = Math.Clamp(l + delta, 0.05, 0.95);
        double Hue(double p, double q, double t)
        {
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            return t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p;
        }
        if (s == 0) return Color.FromArgb(255, (byte)(l * 255), (byte)(l * 255), (byte)(l * 255));
        var q2 = l < 0.5 ? l * (1 + s) : l + s - l * s;
        var p2 = 2 * l - q2;
        return Color.FromArgb(255, (byte)Math.Round(Hue(p2, q2, h + 1.0 / 3) * 255), (byte)Math.Round(Hue(p2, q2, h) * 255), (byte)Math.Round(Hue(p2, q2, h - 1.0 / 3) * 255));
    }
}
