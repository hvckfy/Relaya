namespace Relaya.Platform;

/// Общий форматтер: ядро отдаёт размеры в байтах.
internal static class Format
{
    public static string Bytes(long bytes)
    {
        double v = bytes;
        foreach (var u in new[] { "B", "KB", "MB", "GB", "TB" })
        {
            if (v < 1024) return $"{v:0.#} {u}";
            v /= 1024;
        }
        return $"{v:0.#} PB";
    }

    /// Дата из ядра (ISO 8601) — коротко в локальном времени и формате языка интерфейса (UI-W5).
    public static string Date(string iso) =>
        System.DateTimeOffset.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var t)
            ? t.ToLocalTime().ToString("g") : iso;
}
