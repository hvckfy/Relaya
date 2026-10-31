using System;
using System.IO;

namespace Relaya.Platform;

/// Журналы Relaya (terminal.log, mcp-log.jsonl): дописывание с ограничением размера — настройка logs.maxKB
/// (64–10240, по умолчанию 256). Переросший файл становится `<имя>.old` (один), запись идёт в новый.
internal static class LogFiles
{
    public const int DefaultKB = 256, MinKB = 64, MaxKB = 10240;

    public static int LimitKB =>
        int.TryParse(Settings.GetFresh("logs.maxKB", DefaultKB.ToString()), out var v) ? Math.Clamp(v, MinKB, MaxKB) : DefaultKB;

    public static void Append(string file, string text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            if (File.Exists(file) && new FileInfo(file).Length > LimitKB * 1024L) File.Move(file, file + ".old", overwrite: true);
            var created = !File.Exists(file);
            File.AppendAllText(file, text);
            if (created) AtomicFile.MakePrivate(file); // журналы — только владельцу (M-MCP-2)
        }
        catch (Exception) { }
    }
}
