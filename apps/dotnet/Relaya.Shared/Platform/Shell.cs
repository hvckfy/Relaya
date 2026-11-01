namespace Relaya.Platform;

/// Системная оболочка рабочего стола: открыть папку в файловом менеджере (аудит W12).
/// Реализация — Relaya.Windows/Platform/Shell.Windows.cs (Проводник), Relaya.Linux/Platform/Shell.Linux.cs (xdg-open).
internal static partial class Shell
{
    public static partial void OpenFolder(string path);

    /// Показать файл в файловом менеджере (Windows — выделенным в Проводнике, Linux — папку).
    public static partial void Reveal(string path);

    /// В Корзину, а не насовсем (ключи: восстановить можно из Корзины).
    public static partial void Trash(string path);

    /// Открыть файл приложением по умолчанию.
    public static partial void OpenFile(string path);

    /// Открыть текстовым редактором, а не по ассоциации.
    public static partial void OpenAsText(string path);

    // Типы, которые ассоциация по умолчанию запускает, а не открывает (аудит безопасности по 6.6).
    private static readonly System.Collections.Generic.HashSet<string> Launchable = new(System.StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".bat", ".cmd", ".com", ".scr", ".pif", ".cpl", ".msi", ".msp", ".lnk", ".url", ".appref-ms", ".reg",
        ".vbs", ".vbe", ".js", ".jse", ".wsf", ".wsh", ".hta", ".ps1", ".psm1", ".jar",
        ".desktop", ".sh", ".run", ".appimage",
    };

    /// 6.6 «Открыть в редакторе»: файл с сервера не должен исполниться. Запускаемые типы — текстовым редактором,
    /// остальное — по ассоциации; исполняемый бит платформа снимает сама (Linux — chmod 600).
    public static void OpenForEditing(string path)
    {
        if (Launchable.Contains(System.IO.Path.GetExtension(path))) OpenAsText(path);
        else OpenFile(path);
    }
}
