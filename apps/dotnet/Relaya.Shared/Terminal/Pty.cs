namespace Relaya.Terminal;

/// Запуск — в каждом приложении (Relaya.Windows/Terminal/Pty.Windows.cs, Relaya.Linux/Terminal/Pty.Linux.cs).
internal static partial class Pty
{
    public static partial IPty Spawn(string[] argv, short cols, short rows);
}
