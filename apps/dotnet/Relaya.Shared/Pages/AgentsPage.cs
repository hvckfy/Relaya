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

    private string? filterHost;

    public AgentsPage() => Build();

    private void Build()
    {
        var policy = McpHost.LoadPolicy();
        var (page, body) = Ui.Scaffold(L("Агенты"));
        Content = page;
        if (McpHost.PolicyUnreadable())
            body.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Error,
                IsOpen = true,
                IsClosable = false,
                Title = L("Политика не прочитана — доступ выключен"),
                Message = L("Файл mcp.json повреждён. Агенты не получат доступ, пока вы не сохраните настройки заново.") + "\n" + L("Новая политика — с подтверждением каждой команды; режимы хостов задайте заново."),
                ActionButton = Ui.Button(L("Создать политику заново"), () => { McpHost.ResetPolicy(); Build(); }),
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
            var box = ModeBox(mode, value =>
            {
                var p = McpHost.LoadPolicy();
                var hosts = new Dictionary<string, McpMode>(p.hosts) { [h.alias] = value };
                Save(p with { hosts = hosts });
            });
            // Правила и временный доступ по хосту (10.2, 10.3) — как на Mac: колонки справа, режим последним.
            var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            if (RelayaCoreMethods.McpGrant(policy, h.alias, NowRef()) is { } g)
            {
                trailing.Children.Add(new TextBlock
                {
                    Text = L("%@ до %@", L(Modes[(int)g.mode]), Platform.Format.Time(FromRef(g.until))),
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCautionBrush"],
                });
                trailing.Children.Add(Ui.Button(L("Отозвать"), () => { Revoke(h.alias); Build(); }));
            }
            trailing.Children.Add(RulesButton(h.alias, policy));
            trailing.Children.Add(GrantButton(h.alias));
            trailing.Children.Add(box);
            body.Children.Add(Ui.Row(OsIcon.Glyph(h.os), h.alias, RelayaCoreMethods.HostSubtitle(h), trailing));
        }
        body.Children.Add(Ui.Row("", L("Правила для всех хостов"),
            L("«Без подтверждения» и «Запрещено всегда» для любого хоста — шаблоны команд, как в shell."), RulesButton("*", policy)));

        body.Children.Add(Ui.Section(L("Подключение к Claude")));
        var exe = Environment.ProcessPath ?? "Relaya.exe";
        var snippet = $"{{\n  \"mcpServers\": {{\n    \"relaya\": {{ \"command\": \"{exe.Replace("\\", "\\\\")}\", \"args\": [\"--mcp\"] }}\n  }}\n}}";
        var connect = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        connect.Children.Add(Ui.Button(L("Добавить в Claude Desktop"), async () =>
        {
            await Platform.DesktopLauncher.Message(XamlRoot, AddToClaude(exe));
        }, accent: true));
        connect.Children.Add(Ui.Button(L("Скопировать конфиг"), () => Ui.Copy(snippet)));
        body.Children.Add(Ui.Row("", "Claude Desktop / Claude Code", L("Сервер: %@ --mcp", exe), connect));

        var log = McpHost.Log(500);
        // «Что изменили агенты» (10.5): выполненные изменяющие команды по сессиям агента — правило ядра.
        var summaries = RelayaCoreMethods.McpSummaries(log);
        if (summaries.Count > 0)
        {
            body.Children.Add(Ui.Section(L("Что изменили агенты")));
            foreach (var sm in summaries.Take(10))
            {
                var lines = string.Join("\n", sm.changes.Select(c => $"{c.host}: {c.detail}" + (c.exitCode is { } x and not 0 ? $" · exit {x}" : "")));
                body.Children.Add(Ui.Row("", $"{sm.client} · {string.Join(", ", sm.hosts)}",
                    Platform.Format.Date(sm.started) + "\n" + lines));
            }
        }

        body.Children.Add(Ui.Section(L("Журнал")));
        if (log.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("Агенты ещё ничего не выполняли."))));
        else
        {
            // Фильтр по хосту и очистка журнала (10.4).
            var hosts = new ComboBox { MinWidth = 200 };
            hosts.Items.Add(L("Все хосты"));
            foreach (var h in log.Select(x => x.host).Distinct().OrderBy(x => x)) hosts.Items.Add(h);
            hosts.SelectedIndex = filterHost is { } fh && hosts.Items.Contains(fh) ? hosts.Items.IndexOf(fh) : 0;
            hosts.SelectionChanged += (_, _) => { filterHost = hosts.SelectedIndex > 0 ? hosts.SelectedItem as string : null; Build(); };
            var clear = Ui.Button(L("Очистить журнал"), async () =>
            {
                if (!await Ui.Confirm(XamlRoot, L("Очистить журнал агентов?"), L("Записи о выполненных командах будут удалены."), L("Очистить"))) return;
                McpHost.ClearLog();
                Build();
            });
            body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { hosts, clear } });
        }
        // Ядро отдаёт журнал новыми сверху — показываем 100 последних записей как есть.
        foreach (var e in log.Where(x => filterHost == null || x.host == filterHost).Take(100))
            body.Children.Add(Ui.Row(Allowed(e) ? "" : "",
                $"{e.host}: {e.detail}", $"{Platform.Format.Date(e.date)} · {e.client} · {e.tool} · {L(e.decision)}" + (e.exitCode is { } c ? $" · exit {c}" : "")));
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

    // Время политики — секунды от 2001-01-01, как в mcp.json (общий формат с Mac).
    private const double ReferenceEpoch = 978_307_200;
    private static double NowRef() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 - ReferenceEpoch;
    private static DateTimeOffset FromRef(double r) => DateTimeOffset.FromUnixTimeMilliseconds((long)((r + ReferenceEpoch) * 1000)).ToLocalTime();

    private static void Revoke(string alias)
    {
        var p = McpHost.LoadPolicy();
        if (p.grants == null) return;
        var grants = new Dictionary<string, McpGrant>(p.grants);
        grants.Remove(alias);
        Save(p with { grants = grants.Count > 0 ? grants : null });
    }

    /// Временный доступ «Доверенный» на 30 минут / 2 часа / 8 часов — потом вернётся обычный режим (10.3).
    private DropDownButton GrantButton(string alias)
    {
        var menu = new MenuFlyout();
        foreach (var (minutes, title) in new[] { (30, L("на 30 минут")), (120, L("на 2 часа")), (480, L("на 8 часов")) })
        {
            var item = new MenuFlyoutItem { Text = L("Доверенный %@", title) };
            item.Click += (_, _) =>
            {
                var p = McpHost.LoadPolicy();
                var grants = p.grants != null ? new Dictionary<string, McpGrant>(p.grants) : new Dictionary<string, McpGrant>();
                grants[alias] = new McpGrant(McpMode.Trusted, NowRef() + minutes * 60);
                Save(p with { grants = grants });
                Build();
            };
            menu.Items.Add(item);
        }
        var button = new DropDownButton { Content = new FontIcon { Glyph = "\uE823", FontSize = 16 }, Flyout = menu };
        ToolTipService.SetToolTip(button, L("Временный доступ: потом вернётся обычный режим"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, L("Временный доступ"));
        return button;
    }

    /// «Правила (N)»: шаблоны «без подтверждения» и «запрещено всегда» для хоста или «*» — все хосты (10.2).
    private Button RulesButton(string alias, McpPolicy policy)
    {
        var count = Patterns(policy.allow, alias).Count + Patterns(policy.deny, alias).Count;
        return Ui.Button(count > 0 ? L("Правила (%@)", count.ToString()) : L("Правила"), async () => await EditRules(alias));
    }

    private static List<string> Patterns(Dictionary<string, List<string>>? map, string alias) =>
        map != null && map.TryGetValue(alias, out var list) ? list : new List<string>();

    private async System.Threading.Tasks.Task EditRules(string alias)
    {
        var p = McpHost.LoadPolicy();
        TextBox Box(string header, List<string> lines) => new()
        {
            Header = header,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            MinHeight = 120,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas, monospace"),
            Text = string.Join("\n", lines),
        };
        var allow = Box(L("Без подтверждения"), Patterns(p.allow, alias));
        var deny = Box(L("Запрещено всегда"), Patterns(p.deny, alias));
        var dialog = new ContentDialog
        {
            Title = alias == "*" ? L("Правила для всех хостов") : L("Правила для %@", alias),
            Content = new StackPanel
            {
                Spacing = 12,
                MinWidth = 420,
                Children =
                {
                    Ui.Secondary(L("По одному шаблону в строке, как в shell: systemctl restart *, docker logs *. Запрет сильнее разрешения.")),
                    allow, deny,
                },
            },
            PrimaryButtonText = L("Сохранить"),
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        static List<string> Lines(TextBox b) => b.Text.Split('\r', '\n').Select(l => l.Trim()).Where(l => l.Length > 0).Distinct().ToList();
        static Dictionary<string, List<string>>? Put(Dictionary<string, List<string>>? map, string key, List<string> list)
        {
            var m = map != null ? new Dictionary<string, List<string>>(map) : new Dictionary<string, List<string>>();
            if (list.Count > 0) m[key] = list; else m.Remove(key);
            return m.Count > 0 ? m : null;
        }
        var fresh = McpHost.LoadPolicy();
        Save(fresh with { allow = Put(fresh.allow, alias, Lines(allow)), deny = Put(fresh.deny, alias, Lines(deny)) });
        Build();
    }

    // Сливает сервер relaya в %APPDATA%\Claude\claude_desktop_config.json, не трогая остальные серверы.
    private static string AddToClaude(string exe)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude");
            var file = Path.Combine(dir, "claude_desktop_config.json");
            // Битый или не-объект конфиг Claude не перезаписываем — пользователь потерял бы свои настройки (10.6, как на Mac).
            JsonObject root;
            if (File.Exists(file))
            {
                JsonNode? parsed;
                try { parsed = JsonNode.Parse(File.ReadAllText(file)); }
                catch (System.Text.Json.JsonException) { parsed = null; }
                if (parsed is not JsonObject obj) return L("Файл %@ не JSON-объект — не меняю его. Добавьте конфиг вручную.", file);
                root = obj;
            }
            else root = new JsonObject();
            if (root["mcpServers"] is { } existing && existing is not JsonObject)
                return L("Файл %@ не JSON-объект — не меняю его. Добавьте конфиг вручную.", file);
            var servers = root["mcpServers"] as JsonObject ?? new JsonObject();
            servers["relaya"] = new JsonObject { ["command"] = exe, ["args"] = new JsonArray("--mcp") };
            root["mcpServers"] = servers;
            Directory.CreateDirectory(dir);
            Platform.AtomicFile.Write(file, root.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            return L("Готово. Перезапустите Claude Desktop — Relaya появится в списке инструментов.");
        }
        catch (Exception e)
        {
            return e.Message;
        }
    }
}
