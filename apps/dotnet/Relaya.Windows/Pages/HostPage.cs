using System;
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
    private readonly StackPanel stats = new() { Spacing = 4 };
    private readonly StackPanel docker = new() { Spacing = 4 };
    private readonly StackPanel tmux = new() { Spacing = 4 };
    private readonly StackPanel services = new() { Spacing = 4 };

    public HostPage(SshHost h)
    {
        host = h;
        var more = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Padding = new Thickness(10, 8, 10, 8) };
        more.Flyout = HostActions.Menu(h, more);
        var (page, body) = Ui.Scaffold(h.alias,
            Ui.Button(L("Подключить"), () => MainWindow.Current?.OpenSession(h.alias), accent: true, glyph: ""),
            Ui.Button(L("Файлы"), () => MainWindow.Current?.OpenSftp(h.alias), glyph: ""),
            Ui.Button(L("Изменить"), async () => await HostEditor.Show(XamlRoot, h, false), glyph: ""),
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
        body.Children.Add(Ui.Row("", L("Пароль"), hasPassword ? L("Сохранён в диспетчере учётных данных") : L("Не сохранён"),
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
                item.Click += (_, _) => MainWindow.Current?.OpenSession(h.alias, h.user == "root" ? WithoutSudo(a.command) : a.command);
                menu.Items.Add(item);
            }
            osButtons.Children.Add(new DropDownButton { Content = L("Действия"), Flyout = menu });
        }
        body.Children.Add(Ui.Row(OsIcon.Glyph(h.os), L("Система"), osText, osButtons));

        body.Children.Add(Header(L("Состояние"), () => _ = LoadStats()));
        body.Children.Add(stats);
        body.Children.Add(Header(L("Docker"), () => _ = LoadDocker()));
        body.Children.Add(docker);
        body.Children.Add(Header(L("Сессии tmux"), () => _ = LoadTmux()));
        body.Children.Add(tmux);
        body.Children.Add(Header(L("Службы и порты"), () => _ = LoadServices()));
        body.Children.Add(services);

        Loaded += async (_, _) => await Task.WhenAll(LoadStats(), LoadDocker(), LoadTmux(), LoadServices());
    }

    private void Refresh()
    {
        if (AppState.Host(host.alias) is { } h) MainWindow.Current?.ShowPage(new HostPage(h));
    }

    private static Grid Header(string title, Action reload)
    {
        var g = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto } }, Margin = new Thickness(0, 16, 0, 4) };
        g.Children.Add(new TextBlock { Text = title, Style = Ui.Style("BodyStrongTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center });
        var b = Ui.IconButton("", L("Обновить"), reload);
        Grid.SetColumn(b, 1);
        g.Children.Add(b);
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

    private static string Size(long kb)
    {
        double v = kb;
        foreach (var u in new[] { "K", "M", "G", "T" })
        {
            if (v < 1024) return $"{v:0.#} {u}";
            v /= 1024;
        }
        return $"{v:0.#} P";
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
        stats.Children.Add(Ui.Row("", L("Нагрузка"), $"{s.load1:0.00} / {s.cores} " + L("ядер"),
            new ProgressBar { Width = 160, Maximum = Math.Max(1, s.cores), Value = s.load1 }));
        stats.Children.Add(Ui.Row("", L("Память"), $"{Size(s.memTotal - s.memAvailable)} / {Size(s.memTotal)}",
            new ProgressBar { Width = 160, Maximum = Math.Max(1, s.memTotal), Value = s.memTotal - s.memAvailable }));
        stats.Children.Add(Ui.Row("", L("Диск /"), $"{Size(s.diskUsed)} / {Size(s.diskTotal)}",
            new ProgressBar { Width = 160, Maximum = Math.Max(1, s.diskTotal), Value = s.diskUsed }));
        stats.Children.Add(Ui.Row("", L("Работает"), up.Days > 0 ? L("%@ дн. %@ ч", up.Days, up.Hours) : L("%@ ч %@ мин", up.Hours, up.Minutes)));
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
                if (c.list.Count == 0) { Note(docker, L("Контейнеров нет")); return; }
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
        var list = RelayaCoreMethods.TmuxParse(r.Stdout);
        tmux.Children.Clear();
        if (list.Count == 0) { Note(tmux, r.Status == 255 ? Problem(r) : L("Сессий нет")); return; }
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
            services.Children.Add(Ui.Row("", L("Доступны обновления: %@", updates.Count), string.Join(", ", updates.Take(8))));
        var root = host.user == "root";
        foreach (var u in panel.services.OrderBy(RelayaCoreMethods.ServiceRank).Take(30))
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.IconButton("", L("Логи"),
                () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.ServiceLogsCommand(u.name, root) + "\r")));
            actions.Children.Add(Ui.IconButton("", L("Перезапустить"),
                () => MainWindow.Current?.OpenSession(host.alias, RelayaCoreMethods.ServiceCommand("restart", u.name, root))));
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

    // Ведущий `sudo ` — в начале и после &&, ;, |.
    private static string WithoutSudo(string command) =>
        System.Text.RegularExpressions.Regex.Replace(command, @"(^|&&|;|\|)(\s*)sudo\s+", "$1$2");
}
