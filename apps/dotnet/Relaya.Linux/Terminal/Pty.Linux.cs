namespace Relaya.Terminal;

internal static partial class Pty
{
    public static partial IPty Spawn(string[] argv, short cols, short rows) => new UnixPty(argv, cols, rows);
}
