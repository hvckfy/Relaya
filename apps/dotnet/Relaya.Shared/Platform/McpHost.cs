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

    // Нет файла — "" (политика по умолчанию ядра); "{}" ядро считает закрытой политикой (C18).
    private static string PolicyText() => File.Exists(PolicyFile) ? File.ReadAllText(PolicyFile) : "";

    public static McpPolicy LoadPolicy() => RelayaCoreMethods.McpPolicyDecode(PolicyText());

    /// mcp.json есть, но не читается: ядро закрыло доступ, интерфейс должен об этом сказать.
    public static bool PolicyUnreadable() => RelayaCoreMethods.McpPolicyIsUnreadable(PolicyText());

    public static void SavePolicy(McpPolicy policy)
    {
        Directory.CreateDirectory(Data.AppState.Support);
        AtomicFile.Write(PolicyFile, RelayaCoreMethods.McpPolicyEncode(policy), privateFile: true);
    }

    /// Очистить журнал агентов (вместе с .old).
    public static void ClearLog()
    {
        foreach (var f in new[] { LogFile, LogFile + ".old" }) if (File.Exists(f)) File.Delete(f);
    }

    /// Повреждённую политику — в копию рядом и начать с политики по умолчанию (10.8).
    public static void ResetPolicy()
    {
        if (File.Exists(PolicyFile)) File.Move(PolicyFile, PolicyFile + $".broken-{DateTime.Now:yyyyMMdd-HHmmss}", overwrite: true);
        SavePolicy(RelayaCoreMethods.McpPolicyDecode(""));
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
            // Процесс --mcp без XAML: системное окно (Dialogs). «Нет» по умолчанию — Enter/пробел не одобряют команду.
            const int limit = 1500;
            var shown = command.Length > limit
                ? command[..limit] + "\n…\n" + Strings.L("(показано %@ из %@ символов)", limit, command.Length)
                : command;
            var text = Strings.L("%@ хочет выполнить на %@:", client, host.alias) + "\n\n" + shown;
            return Dialogs.YesNo(text, warning: true);
        }

        public void Log(McpLogEntry entry)
        {
            Directory.CreateDirectory(Data.AppState.Support);
            LogFiles.Append(LogFile, RelayaCoreMethods.McpLogLine(entry) + "\n");
        }

        // B-7: the core stops an agent's retries after a refused login, through the file the app also clears.
        public string LoginGatePath() => LoginGate.File;
    }
}
