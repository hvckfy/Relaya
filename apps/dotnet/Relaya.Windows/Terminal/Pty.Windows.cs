using System;
using System.Linq;
using System.Text;

namespace Relaya.Terminal;

internal static partial class Pty
{
    public static partial IPty Spawn(string[] argv, short cols, short rows) =>
        new ConPty(new PseudoConsole(string.Join(" ", argv.Select(Arg)), cols, rows));

    // Аргумент командной строки Windows (правила CommandLineToArgvW): кавычки и обратные слэши перед ними.
    private static string Arg(string a)
    {
        var sb = new StringBuilder("\"");
        var slashes = 0;
        foreach (var c in a)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { sb.Append('\\', slashes * 2 + 1).Append('"'); }
            else { sb.Append('\\', slashes).Append(c); }
            slashes = 0;
        }
        return sb.Append('\\', slashes * 2).Append('"').ToString();
    }

    // PseudoConsole.cs остаётся без зависимостей — его же собирает smoke-тест.
    private sealed class ConPty(PseudoConsole pc) : IPty
    {
        public event Action<byte[]>? Output { add => pc.Output += value; remove => pc.Output -= value; }
        public event Action<int>? Exited { add => pc.Exited += value; remove => pc.Exited -= value; }
        public event Action<Exception>? HandlerFailed { add => pc.HandlerFailed += value; remove => pc.HandlerFailed -= value; }
        public void Start() => pc.Start();
        public void Write(byte[] data) => pc.Write(data);
        public void Resize(short cols, short rows) => pc.Resize(cols, rows);
        public void Dispose() => pc.Dispose();
    }
}
