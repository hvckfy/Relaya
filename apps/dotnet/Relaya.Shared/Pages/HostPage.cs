using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Карточка хоста, как на Mac: действия, параметры подключения и живые панели (состояние, Docker, tmux, службы, порты).
/// Панели опрашивают сервер обычным ssh без терминала; пароль — через askpass.
internal sealed class HostPage : UserControl
{
    private readonly SshHost host;

    /// Хост карточки — для сочетаний окна (F2 — изменить, Ctrl+Shift+T — подключить, Ctrl+Shift+O — файлы).
    public SshHost Host => host;
    private readonly StackPanel stats = new() { Spacing = 4 };
    private readonly StackPanel docker = new() { Spacing = 4 };
    private readonly StackPanel tmux = new() { Spacing = 4 };
    private readonly StackPanel services = new() { Spacing = 4 };

    public HostPage(SshHost h)
    {
        host = h;
        var more = new Button { Content = new FontIcon { Glyph = "", FontSize = Ui.IconMedium }, Padding = new Thickness(12, 8, 12, 8) };
        more.Flyout = HostActions.Menu(h, more);
        var (page, body) = Ui.Scaffold(h.alias,
            Ui.Button(L("Подключить"), () => MainWindow.Current?.OpenSession(h.alias), accent: true, glyph: ""),
            Ui.Button(L("Файлы"), () => MainWindow.Current?.OpenSftp(h.alias), glyph: ""),
            Ui.Button(L("Изменить"), async () => await HostEditor.Show(XamlRoot, h, false), glyph: ""),
            Ui.Button(L("Вход по ключу…"), () => MainWindow.Current?.ShowPage(new KeyWizardPage(h))),
            more);
        Content = page;
        if (Platform.CredentialStore.Has(h.alias) && Platform.Askpass.RunsCommands(h.alias))
            body.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Informational, IsOpen = true, IsClosable = true, Margin = new Thickness(0, 0, 0, 8),
                Message = L("У хоста есть ProxyCommand/LocalCommand — сохранённый пароль не подставляется автоматически"),
            });

        body.Children.Add(Ui.Secondary(RelayaCoreMethods.HostSubtitle(h)));
        body.Children.Add(Ui.Section(L("Подключение")));
        void Field(string glyph, string title, string? value) { if (!string.IsNullOrEmpty(value)) body.Children.Add(Ui.Row(glyph, title, value)); }
        Field("", L("Адрес"), h.hostName ?? h.alias);
        Field("", L("Пользователь"), h.user);
        Field("", L("Порт"), h.port?.ToString());
        Field("", L("Ключ"), h.identityFile);
        Field("", L("Через хост"), h.proxyJump);
        Field("", L("Группа"), h.group);
        Field("", L("Метки"), h.tags.Count > 0 ? string.Join(", ", h.tags) : null);

        var hasPassword = Platform.CredentialStore.Has(h.alias);
        var passwordButton = Ui.Button(hasPassword ? L("Изменить") : L("Сохранить…"), async () => { await HostEditor.AskPassword(XamlRoot, h.alias); Refresh(); });
        var forget = Ui.Button(L("Забыть"), () => { Platform.CredentialStore.Delete(h.alias); Refresh(); });
        forget.Visibility = hasPassword ? Visibility.Visible : Visibility.Collapsed;
        body.Children.Add(Ui.Row("", L("Пароль"), hasPassword ? Platform.PlatformText.PasswordSaved() : L("Не сохранён"),
            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { passwordButton, forget } }));

        var osText = h.os is { } os ? RelayaCoreMethods.OsTitle(os) : L("Не определена");
        var osButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        osButtons.Children.Add(Ui.Button(L("Определить"), async () => await DetectOs()));
        if (h.os is { } known && RelayaCoreMethods.OsActions(known) is { Count: > 0 } actions)
        {
            var menu = new MenuFlyout();
            foreach (var a in actions)
            {
                var item = new MenuFlyoutItem { Text = L(a.title) };
                // Как на Mac: команда вставляется в терминал без Enter — пользователь видит её и запускает сам.
                // sudo уже в команде ядра; под root его нет смысла звать (а на Alpine его может не быть).
                item.Click += (_, _) => MainWindow.Current?.OpenSession(h.alias, RelayaCoreMethods.OsCommandForUser(a.command, h.user ?? ""));
                menu.Items.Add(item);
            }
            osButtons.Children.Add(new DropDownButton { Content = L("Действия"), Flyout = menu });
        }
        body.Children.Add(Ui.Row(OsIcon.Glyph(h.os), L("Система"), osText, osButtons));

        body.Children.Add(Header(L("Порты"), BuildTunnels));
        body.Children.Add(tunnels);
        BuildTunnels();
        var ui = DispatcherQueue;
        void OnTunnels() => ui.TryEnqueue(BuildTunnels);
        Platform.TunnelManager.Shared.Changed += OnTunnels;
        Unloaded += (_, _) => Platform.TunnelManager.Shared.Changed -= OnTunnels;
        body.Children.Add(Header(L("Состояние"), () => _ = LoadStats()));
        body.Children.Add(stats);
        body.Children.Add(Header(L("Docker"), () => _ = LoadDocker()));
        body.Children.Add(docker);
        // «Завершить все» сессии Relaya на хосте (3.7), с подтверждением.
        body.Children.Add(Header(L("Сессии tmux"), () => _ = LoadTmux(), Ui.Button(L("Завершить все"), async () =>
        {
            var names = RelayaCoreMethods.TmuxParse((await AppState.RunOnHost(host.alias, RelayaCoreMethods.TmuxListCommand())).Stdout)
                .Where(t => RelayaCoreMethods.TmuxIsHostSession(host.alias, t.name)).Select(t => t.name).ToList();
            if (names.Count == 0) return;
            if (!await Ui.Confirm(XamlRoot, L("Завершить все сессии tmux на %@?", host.alias), string.Join("\n", names), L("Завершить"))) return;
            await AppState.RunOnHost(host.alias, RelayaCoreMethods.TmuxKillCommand(names));
            await LoadTmux();
        })));
        body.Children.Add(tmux);
        body.Children.Add(Header(L("Службы и порты"), () => _ = LoadServices()));
        body.Children.Add(services);

        Loaded += async (_, _) => await Task.WhenAll(LoadStats(), LoadDocker(), LoadTmux(), LoadServices());
    }

    private void Refresh()
    {
        if (AppState.Host(host.alias) is { } h) MainWindow.Current?.ShowPage(new HostPage(h));
    }

    // 3.6, как PortsPanel на Mac: туннели этого хоста с переключателями, быстрый проброс по заготовкам, SOCKS,
    // «Свой проброс…» и «Все туннели».
    private static readonly (string Name, long Port, TunnelKind Kind)[] PortPresets =
    {
        ("PostgreSQL", 5432, TunnelKind.Local), ("MySQL / MariaDB", 3306, TunnelKind.Local), ("Redis", 6379, TunnelKind.Local),
        ("MongoDB", 27017, TunnelKind.Local), ("HTTP :80", 80, TunnelKind.Local), ("HTTP :8080", 8080, TunnelKind.Local),
        ("Grafana :3000", 3000, TunnelKind.Local), ("Prometheus :9090", 9090, TunnelKind.Local), ("SOCKS", 1080, TunnelKind.Dynamic),
    };

    private readonly StackPanel tunnels = new() { Spacing = 4 };

    private void BuildTunnels()
    {
        tunnels.Children.Clear();
        var own = AppState.Tunnels.Where(t => t.hostAlias == host.alias).ToList();
        if (own.Count == 0) Note(tunnels, L("Нет пробросов для этого хоста."));
        foreach (var t in own)
        {
            var (state, error) = Platform.TunnelManager.Shared.StatusOf(t);
            var running = state is Platform.TunnelManager.State.Running or Platform.TunnelManager.State.Starting;
            var toggle = new ToggleSwitch { IsOn = running, OnContent = "", OffContent = "", MinWidth = 0 };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, t.name);
            toggle.Toggled += (_, _) => { if (toggle.IsOn) Platform.TunnelManager.Shared.Start(t); else Platform.TunnelManager.Shared.Stop(t.id); };
            tunnels.Children.Add(Ui.Row("", t.name, RelayaCoreMethods.TunnelSpec(t) + (error is { Length: > 0 } e ? " · " + e : ""), toggle));
        }
        var menu = new MenuFlyout();
        foreach (var p in PortPresets)
        {
            var item = new MenuFlyoutItem { Text = p.Kind == TunnelKind.Dynamic ? L("SOCKS-прокси") : p.Name };
            item.Click += (_, _) => Forward(p.Name, p.Port, p.Kind);
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var custom = new MenuFlyoutItem { Text = L("Свой проброс…") };
        custom.Click += (_, _) => MainWindow.Current?.ShowPage(new TunnelsPage(host.alias));
        menu.Items.Add(custom);
        tunnels.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8,
            Children =
            {
                new DropDownButton { Content = L("Пробросить порт"), Flyout = menu },
                Ui.Button(L("Все туннели"), () => MainWindow.Current?.ShowPage(new TunnelsPage())),
            },
        });
    }

    // Привилегированный порт (< 1024) на Linux без root не открыть — локально берём порт + 8000, как на Mac.
    private void Forward(string name, long remotePort, TunnelKind kind)
    {
        // Повторный щелчок по той же заготовке запускает уже созданный туннель, а не второй такой же.
        if (AppState.Tunnels.FirstOrDefault(x => x.hostAlias == host.alias && x.kind == kind && x.targetPort == remotePort) is { } existing)
        {
            Platform.TunnelManager.Shared.Start(existing);
            return;
        }
        var local = remotePort < 1024 ? remotePort + 8000 : remotePort;
        var t = new Tunnel(RelayaCoreMethods.CoreNewId(), kind == TunnelKind.Dynamic ? L("SOCKS-прокси") : name, host.alias, kind,
            local, "localhost", remotePort, false);
        AppState.Tunnels = AppState.Tunnels.Append(t).ToList();
        Platform.TunnelManager.Shared.Start(t);
    }

    private static Grid Header(string title, Action reload, UIElement? extra = null)
    {
        var g = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto } }, Margin = new Thickness(0, 16, 0, 4) };
        g.Children.Add(new TextBlock { Text = title, Style = Ui.Style("BodyStrongTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center });
        var b = Ui.IconButton("", L("Обновить"), reload);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        if (extra != null) tools.Children.Add(extra);
        tools.Children.Add(b);
        Grid.SetColumn(tools, 1);
        g.Children.Add(tools);
        return g;
    }

    private static void Busy(StackPanel panel)
    {
        panel.Children.Clear();
        panel.Children.Add(new ProgressBar { IsIndeterminate = true });
    }

    private static void Note(StackPanel panel, string text)
    {
        panel.Children.Clear();
        panel.Children.Add(Ui.Card(Ui.Secondary(text)));
    }

    private async Task LoadStats()
    {
        Busy(stats);
        var r = await AppState.RunOnHost(host.alias, RelayaCoreMethods.HostStatsProbeCommand());
        if (r.Status != 0 || RelayaCoreMethods.HostStatsParse(r.Stdout) is not { } s)
        {
            Note(stats, r.Status == 0 ? L("Нет данных (не Linux?)") : Problem(r));
            return;
        }
        stats.Children.Clear();
        var up = TimeSpan.FromSeconds(s.uptime);
        var uptime = up.Days > 0 ? L("%@ дн. %@ ч", up.Days, up.Hours) : L("%@ ч %@ мин", up.Hours, up.Minutes);
        var used = s.memTotal - s.memAvailable;
        var metrics = new (string Glyph, string Title, string Value, double Part)[]
        {
            ("\uE9D9", L("Нагрузка"), $"{s.load1:0.00} / {s.cores} " + L("ядер"), s.load1 / Math.Max(1, s.cores)),
            ("\uE964", L("Память"), $"{Platform.Format.Bytes(used)} / {Platform.Format.Bytes(s.memTotal)}", (double)used / Math.Max(1, s.memTotal)),
            ("\uEDA2", L("Диск /"), $"{Platform.Format.Bytes(s.diskUsed)} / {Platform.Format.Bytes(s.diskTotal)}", (double)s.diskUsed / Math.Max(1, s.diskTotal)),
        };
        // Вид блока «Состояние» (3.3, 12.3) — как на Mac: плитки, компактный список, пиксельные полосы, консоль.
        switch (Platform.Settings.Get(StatsStyleKey, "tiles"))
        {
            case "compact":
                foreach (var m in metrics)
                    stats.Children.Add(Ui.Row(m.Glyph, m.Title, m.Value, new ProgressBar { Width = 160, Maximum = 1, Value = Math.Min(1, m.Part) }));
                stats.Children.Add(Ui.Row("\uE916", L("Работает"), uptime));
                break;
            case "pixel":
            case "console":
            {
                var pixel = Platform.Settings.Get(StatsStyleKey, "tiles") == "pixel";
                string Bar(double part)
                {
                    var n = (int)Math.Round(Math.Clamp(part, 0, 1) * 20);
                    return pixel ? new string('█', n) + new string('░', 20 - n) : "[" + new string('#', n) + new string('.', 20 - n) + "]";
                }
                var lines = metrics.Select(m => $"{m.Title,-10} {Bar(m.Part)} {m.Value}").Append($"{L("Работает"),-10} {uptime}");
                stats.Children.Add(Ui.Card(new TextBlock
                {
                    Text = string.Join("\n", lines), FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas, monospace"),
                    IsTextSelectionEnabled = true,
                }));
                break;
            }
            default:
            {
                var tiles = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 180, ItemHeight = 96 };
                foreach (var m in metrics) tiles.Children.Add(Tile(m.Title, m.Value, m.Part));
                tiles.Children.Add(Tile(L("Работает"), uptime, null));
                stats.Children.Add(tiles);
                break;
            }
        }
    }

    public const string StatsStyleKey = "host.statsStyle";

    private static UIElement Tile(string title, string value, double? part)
    {
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(Ui.Secondary(title));
        panel.Children.Add(new TextBlock { Text = value, Style = Ui.Style("SubtitleTextBlockStyle"), TextWrapping = TextWrapping.Wrap });
        if (part is { } p) panel.Children.Add(new ProgressBar { Maximum = 1, Value = Math.Min(1, p) });
        var card = Ui.Card(panel);
        card.Margin = new Thickness(0, 0, 8, 8);
        return card;
    }

    private static string Problem(AppState.Result r) => Platform.SshErrors.Describe(r.Stderr, L("Не удалось подключиться"));

    private async Task LoadDocker()
    {
        Busy(docker);
        var r = await AppState.RunOnHost(host.alias, RelayaCoreMethods.DockerListCommand());
        switch (RelayaCoreMethods.DockerParse(r.Stdout, r.Stderr, r.Status))
        {
            case DockerList.NotInstalled: Note(docker, L("Docker не установлен")); return;
            case DockerList.PermissionDenied: Note(docker, L("Нет прав на Docker (добавьте пользователя в группу docker)")); return;
            case DockerList.Failed f: Note(docker, r.Status == 255 ? Problem(r) : f.message); return;
            case DockerList.Containers c:
                docker.Children.Clear();
                if (c.list.Count == 0) { Note(docker, L("Контейнеров нет.")); return; }
                foreach (var ct in c.list)
                {
                    var running = ct.state is "running" or "restarting";
                    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                    actions.Children.Add(Ui.IconButton("", L("Логи"),
                        () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.DockerLogsCommand(ct.name) + "\r")));
                    if (running)
                    {
                        actions.Children.Add(Ui.IconButton("", L("Shell"),
                            () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.DockerShellCommand(ct.name) + "\r")));
                        actions.Children.Add(Ui.IconButton("", L("Перезапустить"), () => _ = DockerAction("restart", ct.name)));
                        actions.Children.Add(Ui.IconButton("", L("Остановить"), () => _ = DockerAction("stop", ct.name)));
                    }
                    else
                    {
                        actions.Children.Add(Ui.IconButton("", L("Запустить"), () => _ = DockerAction("start", ct.name)));
                    }
                    docker.Children.Add(Ui.Row(running ? "" : "", ct.name, $"{ct.image} · {ct.status}" + (ct.ports.Length > 0 ? $" · {ct.ports}" : ""), actions));
                }
                return;
        }
    }

    private async Task DockerAction(string action, string name)
    {
        Busy(docker);
        var r = await AppState.RunOnHost(host.alias, RelayaCoreMethods.DockerActionCommand(action, name), 60);
        if (r.Status != 0) await Platform.DesktopLauncher.Message(XamlRoot, r.Stderr.Trim());
        await LoadDocker();
    }

    private async Task LoadTmux()
    {
        Busy(tmux);
        var r = await AppState.RunOnHost(host.alias, RelayaCoreMethods.TmuxListCommand());
        // Как на Mac (К10): только сессии Relaya этого хоста; брошенные дольше настройки tmux.idle — убираем,
        // кроме открытых во вкладках.
        var list = RelayaCoreMethods.TmuxParse(r.Stdout).Where(s => RelayaCoreMethods.TmuxIsHostSession(host.alias, s.name)).ToList();
        var ttl = long.TryParse(Platform.Settings.Get("tmux.idle", "60"), out var idle) ? idle : 60;
        var stale = RelayaCoreMethods.TmuxStale(list, host.alias, MainWindow.Current?.OpenTmuxNames ?? new List<string>(), ttl,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
        if (stale.Count > 0)
        {
            await AppState.RunOnHost(host.alias, RelayaCoreMethods.TmuxKillCommand(stale));
            list = list.Where(s => !stale.Contains(s.name)).ToList();
        }
        tmux.Children.Clear();
        if (list.Count == 0) { Note(tmux, r.Status == 255 ? Problem(r) : L("Сессий нет.")); return; }
        foreach (var s in list)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.Button(L("Подключиться"),
                () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.TmuxAttachCommand(s.name, long.TryParse(Platform.Settings.Get("tmux.idle", "60"), out var ttl) ? ttl : 60) + "\r")));
            actions.Children.Add(Ui.IconButton("", L("Завершить"), async () =>
            {
                await AppState.RunOnHost(host.alias, RelayaCoreMethods.TmuxKillCommand(new() { s.name }));
                await LoadTmux();
            }));
            var created = DateTimeOffset.FromUnixTimeSeconds((long)s.created).LocalDateTime;
            tmux.Children.Add(Ui.Row("", s.name,
                (RelayaCoreMethods.TmuxIsHostSession(host.alias, s.name) ? L("вкладка Relaya") + " · " : "") +
                (s.attached > 0 ? L("подключено: %@", s.attached) : L("отключена")) + " · " + created.ToString("g"), actions));
        }
    }

    private async Task LoadServices()
    {
        Busy(services);
        var r = await AppState.RunOnHost(host.alias, RelayaCoreMethods.HostPanelProbeCommand(host.os), 45);
        if (r.Status == 255) { Note(services, Problem(r)); return; }
        var panel = RelayaCoreMethods.HostPanelParse(r.Stdout);
        services.Children.Clear();
        if (panel.updates is { Count: > 0 } updates)
            services.Children.Add(Ui.Row("", L("Доступно обновлений: %@", updates.Count), string.Join(", ", updates.Take(8))));
        var root = host.user == "root";
        foreach (var u in panel.services.OrderBy(RelayaCoreMethods.ServiceRank).Take(30))
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.IconButton("", L("Логи"),
                () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.ServiceLogsCommand(u.name, root) + "\r")));
            actions.Children.Add(Ui.IconButton("", L("Перезапустить"),
                () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.ServiceCommand("restart", u.name, root))));
            // Запуск и остановка (3.5): команда вставляется в терминал, как перезапуск, — человек видит её и запускает.
            if (u.active == "active")
                actions.Children.Add(Ui.IconButton("\uE71A", L("Остановить"),
                    () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.ServiceCommand("stop", u.name, root))));
            else
                actions.Children.Add(Ui.IconButton("\uE768", L("Запустить"),
                    () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.ServiceCommand("start", u.name, root))));
            services.Children.Add(Ui.Row(u.active == "active" ? "" : "", u.name, $"{u.active}/{u.sub} · {u.description}", actions));
        }
        foreach (var p in panel.ports.Where(p => p.port != null).Take(30))
        {
            var port = p.port!.Value;
            var open = Ui.Button(L("Пробросить"), () =>
            {
                var t = new Tunnel(RelayaCoreMethods.CoreNewId(), $"{host.alias}:{port}", host.alias, TunnelKind.Local, port, "localhost", port, false);
                AppState.Tunnels = AppState.Tunnels.Append(t).ToList();
                Platform.TunnelManager.Shared.Start(t);
                MainWindow.Current?.ShowPage(new TunnelsPage());
            });
            services.Children.Add(Ui.Row("", $"{p.proto} {p.address}:{port}", p.process, open));
        }
        if (services.Children.Count == 0) Note(services, panel.hasSystemd ? L("Нет данных") : L("systemd не найден"));
    }

    private async Task DetectOs()
    {
        var r = await AppState.RunOnHost(host.alias, RelayaCoreMethods.OsProbeCommand());
        if (RelayaCoreMethods.OsParseProbe(r.Stdout) is { } os)
        {
            AppState.SetMeta(host with { os = os }); // только строка `# relaya:` (C2)
            Refresh();
        }
        else
        {
            await Platform.DesktopLauncher.Message(XamlRoot, r.Status == 0 ? L("Не удалось определить систему") : Problem(r));
        }
    }

}
