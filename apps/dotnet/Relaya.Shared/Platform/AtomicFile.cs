using System.IO;

namespace Relaya.Platform;

/// Атомарная запись файла пользователя: временный файл рядом, затем замена (Н7). Сбой посреди записи
/// оставляет прежний файл целым, а не обрезанный JSON.
internal static class AtomicFile
{
    /// privateFile — только владелец (0600) на Linux/macOS: политика агентов и журналы (M-MCP-2).
    public static void Write(string path, string text, bool privateFile = false)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, text);
        if (privateFile) MakePrivate(tmp);
        File.Move(tmp, path, overwrite: true);
    }

    public static void MakePrivate(string path)
    {
        if (!System.OperatingSystem.IsWindows())
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
}
