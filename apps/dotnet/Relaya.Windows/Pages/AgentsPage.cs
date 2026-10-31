using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using Relaya.Platform;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// AI-агенты (MCP): включение, уровень доступа по умолчанию и по хостам, журнал команд, подключение к Claude.
/// Политика — mcp.json в общем формате с Mac; сам сервер — `Relaya.exe --mcp`.
internal sealed class AgentsPage : UserControl
{
    private static readonly string[] Modes = { "Нет доступа", "Только чтение", "С подтверждением", "Доверенный" };

    public AgentsPage() => Build();

    private void Build()
    {
        var policy = McpHost.LoadPolicy();
        var (page, body) = Ui.Scaffold(L("Агенты"));
        Content = page;
        if (McpHost.PolicyUnreadable())
            body.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Error, IsOpen = true, IsClosable = false,
                Title = L("Политика не прочитана — доступ выключен"),
                Message = L("Файл mcp.json повреждён. Агенты не получат доступ, пока вы не сохраните настройки заново."),
            });

        var enabled = new ToggleSwitch { IsOn = policy.enabled, OnContent = "", OffContent = "", MinWidth = 0 };
        enabled.Toggled += (_, _) => Save(McpHost.LoadPolicy() with { enabled = enabled.IsOn });
        body.Children.Add(Ui.Row("", L("Доступ AI-агентов к серверам"),
            L("Claude и другие MCP-клиенты выполняют команды на ваших хостах в рамках правил ниже. Каждая команда пишется в журнал."), enabled));

        body.Children.Add(Ui.Row("", L("По умолчанию"), L("Для хостов без своего правила"), ModeBox(policy.defaultMode,
            m => Save(McpHost.LoadPolicy() with { defaultMode = m }))));

        body.Children.Add(Ui.Section(L("Хосты")));
        foreach (var h in AppState.Hosts)
        {
            var mode = policy.hosts.TryGetValue(h.alias, out var m) ? m : policy.defaultMode;
            body.Children.Add(Ui.Row(OsIcon.Glyph(h.os), h.alias, RelayaCoreMethods.HostSubtitle(h), ModeBox(mode, value =>
            {
                var p = McpHost.LoadPolicy();
                var hosts = new Dictionary<string, McpMode>(p.hosts) { [h.alias] = value };
                Save(p with { hosts = hosts });
            })));
        }

        body.Children.Add(Ui.Section(L("Подключение к Claude")));
        var exe = Environment.ProcessPath ?? "Relaya.exe";
        var snippet = $"{{\n  \"mcpServers\": {{\n    \"relaya\": {{ \"command\": \"{exe.Replace("\\", "\\\\")}\", \"args\": [\"--mcp\"] }}\n  }}\n}}";
        var connect = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        connect.Children.Add(Ui.Button(L("Добавить в Claude Desktop"), async () =>
        {
            await Platform.DesktopLauncher.Message(XamlRoot, AddToClaude(exe));
        }, accent: true));
        connect.Children.Add(Ui.Button(L("Копировать конфиг"), () => Ui.Copy(snippet)));
        body.Children.Add(Ui.Row("", "Claude Desktop / Claude Code", L("Сервер: %@ --mcp", exe), connect));

        body.Children.Add(Ui.Section(L("Журнал")));
        var log = McpHost.Log(200);
        if (log.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("Агенты ещё ничего не выполняли."))));
        foreach (var e in Enumerable.Reverse(log).Take(100))
            body.Children.Add(Ui.Row(Allowed(e) ? "" : "",
                $"{e.host}: {e.detail}", $"{e.date} · {e.client} · {e.tool} · {e.decision}" + (e.exitCode is { } c ? $" · exit {c}" : "")));
    }

    // Иконка по машинному коду решения из ядра (W13); у старых записей кода нет — по тексту.
    private static bool Allowed(McpLogEntry e) => e.decisionCode switch
    {
        McpDecision.AllowedRule or McpDecision.AllowedRead or McpDecision.ApprovedByUser
            or McpDecision.AllowedGrant or McpDecision.AllowedTrusted => true,
        null => e.decision.StartsWith("разрешено") || e.decision.StartsWith("одобрено") || e.decision.StartsWith("allow") || e.decision == "ok",
        _ => false,
    };

    private static ComboBox ModeBox(McpMode mode, Action<McpMode> changed)
    {
        var box = new ComboBox { MinWidth = 200 };
        foreach (var m in Modes) box.Items.Add(L(m));
        box.SelectedIndex = (int)mode;
        box.SelectionChanged += (_, _) => changed((McpMode)box.SelectedIndex);
        return box;
    }

    private static void Save(McpPolicy p) => McpHost.SavePolicy(p);

    // Сливает сервер relaya в %APPDATA%\Claude\claude_desktop_config.json, не трогая остальные серверы.
    private static string AddToClaude(string exe)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude");
            var file = Path.Combine(dir, "claude_desktop_config.json");
            var root = File.Exists(file) ? JsonNode.Parse(File.ReadAllText(file)) as JsonObject ?? new JsonObject() : new JsonObject();
            var servers = root["mcpServers"] as JsonObject ?? new JsonObject();
            servers["relaya"] = new JsonObject { ["command"] = exe, ["args"] = new JsonArray("--mcp") };
            root["mcpServers"] = servers;
            Directory.CreateDirectory(dir);
            File.WriteAllText(file, root.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            return L("Готово. Перезапустите Claude Desktop — Relaya появится в списке инструментов.");
        }
        catch (Exception e)
        {
            return e.Message;
        }
    }
}
