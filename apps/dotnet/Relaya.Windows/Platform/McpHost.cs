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
        Console.InputEncoding = Encoding.UTF8;
        Console.OutputEncoding = new UTF8Encoding(false);
        Data.AppState.LoadHosts();
        var server = new McpServer(new Backend());
        string? line;
        while ((line = Console.In.ReadLine()) != null)
        {
            if (line.Trim().Length == 0) continue;
            if (server.Handle(line) is { } reply)
            {
                Console.Out.Write(reply + "\n");
                Console.Out.Flush();
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
        public List<SshHost> Hosts() => Data.AppState.Hosts;

        public McpPolicy Policy() => LoadPolicy();

        public ExecResult Execute(SshHost host, string command, uint timeoutSeconds)
        {
            var r = Data.AppState.RunOnHost(host.alias, command, (int)timeoutSeconds).GetAwaiter().GetResult();
            return new ExecResult(r.Status, r.Stdout, r.Stderr);
        }

        // Подтверждение каждой команды — системное окно поверх всех (Touch ID на Mac).
        public bool Confirm(SshHost host, string command, string client)
        {
            var text = Strings.L("%@ хочет выполнить на %@:", client, host.alias) + "\n\n" + command;
            return MessageBoxW(IntPtr.Zero, text, "Relaya", 0x4 | 0x20 | 0x40000 | 0x10000) == 6;
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
