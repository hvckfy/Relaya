using System.IO;

namespace Relaya.Platform;

/// Атомарная запись файла пользователя: временный файл рядом, затем замена (Н7). Сбой посреди записи
/// оставляет прежний файл целым, а не обрезанный JSON.
internal static class AtomicFile
{
    public static void Write(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, text);
        File.Move(tmp, path, overwrite: true);
    }
}
