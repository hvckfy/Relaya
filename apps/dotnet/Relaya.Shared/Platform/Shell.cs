namespace Relaya.Platform;

/// Системная оболочка рабочего стола: открыть папку в файловом менеджере (аудит W12).
/// Реализация — Relaya.Windows/Platform/Shell.Windows.cs (Проводник), Relaya.Linux/Platform/Shell.Linux.cs (xdg-open).
internal static partial class Shell
{
    public static partial void OpenFolder(string path);
}
