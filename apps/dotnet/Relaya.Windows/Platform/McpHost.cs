using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using uniffi.relaya_core;

namespace Relaya.Platform;

/// `Relaya.exe --mcp`: MCP-сервер для AI-агентов (JSON-RPC по stdin/stdout, без окна) — тот же сервер ядра, что на Mac.
/// Политика и журнал — %APPDATA%\Relaya\mcp.json и mcp-log.jsonl (формат общий с Mac).
internal static class McpHost
{
    public static int Run()
    {
        // WinExe без консоли: Console.InputEncoding бросает IOException (SetConsoleCP), поэтому UTF-8 — прямо на потоках.
        using var input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
        using var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { NewLine = "\n" };
        Data.AppState.LoadHosts();
        var server = new McpServer(new Backend());
        string? line;
        while ((line = input.ReadLine()) != null)
        {
            if (line.Trim().Length == 0) continue;
            if (server.Handle(line) is { } reply)
            {
                output.Write(reply + "\n");
                output.Flush();
            }
        }
        return 0;
    }

    private static readonly string PolicyFile = Path.Combine(Data.AppState.Support, "mcp.json");
    private static readonly string LogFile = Path.Combine(Data.AppState.Support, "mcp-log.jsonl");

    public static McpPolicy LoadPolicy() =>
        RelayaCoreMethods.McpPolicyDecode(File.Exists(PolicyFile) ? File.ReadAllText(PolicyFile) : "{}");

    public static void SavePolicy(McpPolicy policy)
    {
        Directory.CreateDirectory(Data.AppState.Support);
        File.WriteAllText(PolicyFile, RelayaCoreMethods.McpPolicyEncode(policy));
    }

    public static List<McpLogEntry> Log(uint limit = 500) =>
        RelayaCoreMethods.McpLogParse(File.Exists(LogFile) ? File.ReadAllText(LogFile) : "", limit);

    private sealed class Backend : McpBackend
    {
        // ~/.ssh/config мог измениться, пока агент держит сервер открытым.
        public List<SshHost> Hosts()
        {
            Data.AppState.LoadHosts();
            return Data.AppState.Hosts;
        }

        public McpPolicy Policy() => LoadPolicy();

        public ExecResult Execute(SshHost host, string command, uint timeoutSeconds)
        {
            var r = Data.AppState.RunOnHost(host.alias, command, (int)timeoutSeconds).GetAwaiter().GetResult();
            return new ExecResult(r.Status, r.Stdout, r.Stderr);
        }

        // Подтверждение каждой команды — системное окно поверх всех (Touch ID на Mac).
        public bool Confirm(SshHost host, string command, string client)
        {
            // Процесс --mcp без XAML: системное окно. «Нет» по умолчанию (MB_DEFBUTTON2) — Enter/пробел не одобряют команду.
            const int limit = 1500;
            var shown = command.Length > limit
                ? command[..limit] + "\n…\n" + Strings.L("(показано %@ из %@ символов)", limit, command.Length)
                : command;
            var text = Strings.L("%@ хочет выполнить на %@:", client, host.alias) + "\n\n" + shown;
            const uint flags = 0x4 /* YESNO */ | 0x30 /* ICONWARNING */ | 0x100 /* DEFBUTTON2 */ | 0x40000 /* TOPMOST */ | 0x10000 /* SETFOREGROUND */;
            return MessageBoxW(IntPtr.Zero, text, "Relaya", flags) == 6;
        }

        public void Log(McpLogEntry entry)
        {
            Directory.CreateDirectory(Data.AppState.Support);
            File.AppendAllText(LogFile, RelayaCoreMethods.McpLogLine(entry) + "\n");
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
}
