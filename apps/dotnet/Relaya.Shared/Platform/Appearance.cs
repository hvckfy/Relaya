using System.Globalization;
using System.IO;

namespace Relaya.Platform;

/// Картинка фона рабочей области (12.2), как на Mac: одна на всё окно, терминалы и разделы просвечивают её
/// с заданной непрозрачностью. Значения — в Settings; окно и терминалы перерисовываются по Settings.Changed.
internal static class Appearance
{
    public const double MinOpacity = 0.2;

    /// Путь к картинке или null; файл, которого нет, считается «картинки нет».
    public static string? ImagePath =>
        Settings.Get("app.backgroundImage", "") is { Length: > 0 } p && File.Exists(p) ? p : null;

    public static bool UnderSessions => Settings.Get("app.backgroundUnderSessions", "1") == "1";
    public static bool UnderInterface => Settings.Get("app.backgroundUnderInterface", "1") == "1";

    /// Непрозрачность панелей поверх картинки: 0.2 — почти прозрачно, 1 — картинки не видно.
    public static double PanelOpacity =>
        double.TryParse(Settings.Get("app.backgroundOpacity", "0.85"), NumberStyles.Float, CultureInfo.InvariantCulture, out var v)
            ? System.Math.Clamp(v, MinOpacity, 1) : 0.85;

    /// Непрозрачность фона терминала: с картинкой под сессиями — PanelOpacity, иначе 1.
    public static double SessionOpacity => ImagePath != null && UnderSessions ? PanelOpacity : 1;
}
