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
}
