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

    /// Открыть файл приложением по умолчанию (6.6 «Открыть в редакторе»).
    public static partial void OpenFile(string path);
}
