using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Ключи — файлы в ~/.ssh (как на Mac): список с отпечатками, создание ed25519, копирование публичного ключа,
/// установка на хост (authorized_keys) через терминал, чтобы пароль ввёл человек или askpass.
internal sealed class KeysPage : UserControl
{
    public KeysPage() => _ = Build();

    private async Task Build()
    {
        var (page, body) = Ui.Scaffold(L("Ключи"), Ui.Button(L("Новый ключ"), async () => await Create(), accent: true, glyph: ""));
        Content = page;
        var configHosts = RelayaCoreMethods.ParseConfig(AppState.ConfigText());
        // ssh-agent: какие ключи загружены (ssh-add -l). Служба выключена — пункты агента не показываем.
        var agent = await AppState.Run(AppState.SshAddExe, new[] { "-l" }, null, null, 10);
        var agentAvailable = agent.Status is 0 or 1; // 1 — агент работает, но ключей нет
        var agentKeys = agent.Status == 0
            ? agent.Stdout.Split('\n').Select(l => l.Split(' ').ElementAtOrDefault(1) ?? "").Where(f => f.StartsWith("SHA256:")).ToList()
            : new List<string>();
        var pubs = Directory.Exists(AppState.SshDir) ? Directory.GetFiles(AppState.SshDir, "*.pub").OrderBy(p => p).ToList() : new();
        if (pubs.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("В ~/.ssh нет ключей. Создайте ключ ed25519 — его можно установить на хосты и входить без пароля."))));
        foreach (var pub in pubs)
        {
            var name = Path.GetFileNameWithoutExtension(pub);
            var r = await AppState.Run(AppState.KeygenExe, new[] { "-lf", pub }, null, null, 10);
            var fingerprint = r.Status == 0 ? r.Stdout.Trim() : L("не удалось прочитать");
            var used = RelayaCoreMethods.ConfigKeyHosts(AppState.ConfigText(), "~/.ssh/" + name);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.Button(L("Хосты…"), async () => await EditHosts(name)));
            actions.Children.Add(Ui.Button(L("Копировать публичный ключ"), () => Ui.Copy(File.ReadAllText(pub).Trim())));
            var install = new MenuFlyout();
            foreach (var h in AppState.Hosts)
            {
                var item = new MenuFlyoutItem { Text = h.alias };
                item.Click += (_, _) => Install(pub, h.alias);
                install.Items.Add(item);
            }
            actions.Children.Add(new DropDownButton { Content = L("Установить на хост"), Flyout = install });
            // «…»: Проводник, ssh-agent, удаление в Корзину (7.3, 7.6, 7.7).
            var keyPath = Path.Combine(AppState.SshDir, name);
            var more = new MenuFlyout();
            void MoreItem(string text, Action act) { var i = new MenuFlyoutItem { Text = text }; i.Click += (_, _) => act(); more.Items.Add(i); }
            MoreItem(Platform.PlatformText.RevealInFileManager(), () => Platform.Shell.Reveal(keyPath));
            var inAgent = agentKeys.Any(f => fingerprint.Contains(f));
            if (agentAvailable)
                MoreItem(inAgent ? L("Убрать из агента") : L("Добавить в агент"), () => _ = ToggleAgent(keyPath, inAgent));
            more.Items.Add(new MenuFlyoutSeparator());
            MoreItem(L("В Корзину…"), () => _ = TrashKey(keyPath, used));
            var moreButton = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = Ui.IconMedium }, Flyout = more };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(moreButton, L("Ещё"));
            actions.Children.Add(moreButton);
            var created = File.GetCreationTime(pub).ToString("d");
            var details = fingerprint + "\n" + L("Создан %@", created) + (agentAvailable ? " · " + (inAgent ? L("в ssh-agent") : L("не в агенте")) : "");
            var row = Ui.Row("", name, details, actions);
            if (used.Count > 0)
            {
                // Хосты ключа с иконкой: сервер или git-сервер (как на Mac).
                var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(0, 4, 0, 0) };
                foreach (var alias in used)
                {
                    var git = IsGit(alias, configHosts);
                    var chip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                    chip.Children.Add(new FontIcon { Glyph = git ? GitGlyph : ServerGlyph, FontSize = Ui.IconSmall });
                    chip.Children.Add(Ui.Secondary(alias));
                    ToolTipService.SetToolTip(chip, git ? L("Git-сервер") : L("Сервер"));
                    chips.Children.Add(chip);
                }
                ((Panel)((Grid)row.Child).Children[1]).Children.Add(chips);
            }
            body.Children.Add(row);
        }
    }

    private const string ServerGlyph = "\ue756", GitGlyph = "\ue943";

    // Git-сервер — по ядру (User git, github.com и т. п.); записи без блока (только что добавленные полем) — тоже git.
    private static bool IsGit(string alias, System.Collections.Generic.List<SshHost> config) =>
        config.FirstOrDefault(h => h.alias == alias) is not { } h || RelayaCoreMethods.HostIsGitService(h);

    // Какие хосты и git-серверы ходят только с этим ключом: IdentityFile + IdentitiesOnly yes (логика ядра, как на Mac).
    // Так лечится «Too many authentication failures», когда ssh-agent перебирает все ключи.
    private async Task EditHosts(string name)
    {
        var key = "~/.ssh/" + name;
        var text = AppState.ConfigText();
        var all = RelayaCoreMethods.ConfigAllAliases(text);
        var config = RelayaCoreMethods.ParseConfig(text);
        var selected = RelayaCoreMethods.ConfigKeyHosts(text, key).ToHashSet();
        var servers = new StackPanel { Spacing = 4 };
        var gits = new StackPanel { Spacing = 4 };
        void Add(string alias)
        {
            var git = IsGit(alias, config);
            var box = new CheckBox { Content = alias, IsChecked = selected.Contains(alias), Tag = alias };
            if (AppState.Host(alias) is { } h) ToolTipService.SetToolTip(box, RelayaCoreMethods.HostSubtitle(h));
            (git ? gits : servers).Children.Add(box);
        }
        foreach (var a in all) Add(a);
        var server = new TextBox { PlaceholderText = "gitlab.com", Header = L("Git-сервер"), MinWidth = 280 };
        void AddGit()
        {
            // `git@gitlab.com` → `gitlab.com`: пользователя git для нового блока ставит ядро (config_bind_key).
            var n = server.Text.Trim();
            if (n.LastIndexOf('@') is var at and >= 0) n = n[(at + 1)..];
            if (n.Length == 0 || n.Contains(' ') || all.Contains(n)) return;
            all.Add(n);
            selected.Add(n);
            Add(n);
            server.Text = "";
        }
        server.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; AddGit(); } };
        var addButton = Ui.Button(L("Добавить"), AddGit);
        addButton.VerticalAlignment = VerticalAlignment.Bottom;
        var d = new ContentDialog
        {
            Title = L("Хосты, которые ходят с %@", name),
            Content = new ScrollViewer
            {
                MaxHeight = 520,
                Content = new StackPanel
                {
                    Spacing = 8, MinWidth = 420,
                    Children =
                    {
                        Ui.Section(L("Серверы")),
                        servers,
                        Ui.Secondary(L("Для выбранных в ~/.ssh/config ставится IdentityFile этого ключа и IdentitiesOnly yes — ssh не будет перебирать другие ключи агента. Перед записью делается копия config.relaya.bak.")),
                        Ui.Section(L("Git-серверы")),
                        gits,
                        new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { server, addButton } },
                        Ui.Secondary(L("GitHub, GitLab, свой Gitea или Forgejo: вход как git с этим ключом. Git-серверы не показываются среди хостов и не синхронизируются.")),
                    },
                },
            },
            PrimaryButtonText = L("Сохранить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await d.ShowAsync() != ContentDialogResult.Primary) return;
        var hosts = servers.Children.Concat(gits.Children).OfType<CheckBox>().Where(c => c.IsChecked == true).Select(c => (string)c.Tag).ToList();
        AppState.WriteConfig(RelayaCoreMethods.ConfigBindKey(AppState.ConfigText(), key, hosts));
        await Build();
    }

    private async Task ToggleAgent(string keyPath, bool remove)
    {
        var r = remove
            ? await AppState.Run(AppState.SshAddExe, new[] { "-d", keyPath }, null, null, 10)
            : await Platform.KeyGen.AddToAgentAsync(keyPath, await AskPassphrase() ?? "") ? new AppState.Result(0, "", "") : new AppState.Result(1, "", L("Не удалось добавить ключ в агент"));
        if (r.Status != 0) await Ui.ShowError(XamlRoot, L("ssh-agent"), r.Stderr.Trim());
        await Build();
    }

    private async Task<string?> AskPassphrase()
    {
        var box = new PasswordBox { Header = L("Passphrase ключа, если есть") };
        var d = new ContentDialog
        {
            Title = L("Добавить в агент"), Content = box, PrimaryButtonText = L("Добавить"), CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        return await d.ShowAsync() == ContentDialogResult.Primary ? box.Password : null;
    }

    private async Task TrashKey(string keyPath, List<string> used)
    {
        var text = used.Count > 0
            ? L("Перестанут подключаться по этому ключу: %@. Файлы можно будет восстановить из Корзины.", string.Join(", ", used))
            : L("Ключ не указан ни у одного хоста в ~/.ssh/config. Файлы можно будет восстановить из Корзины.");
        if (!await Ui.Confirm(XamlRoot, L("Переместить %@ в Корзину?", Path.GetFileName(keyPath)), text, L("В Корзину"))) return;
        try
        {
            if (File.Exists(keyPath)) Platform.Shell.Trash(keyPath);
            if (File.Exists(keyPath + ".pub")) Platform.Shell.Trash(keyPath + ".pub");
        }
        catch (Exception e) { await Ui.ShowError(XamlRoot, L("Не удалось удалить"), e.Message); }
        await Build();
    }

    // Ключ дописывается в authorized_keys без дублей; команда видна в терминале (пароль — человек или askpass).
    private static void Install(string pub, string alias)
    {
        var key = File.ReadAllText(pub).Trim().Replace("'", "");
        var command = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && " +
                      $"(grep -qxF '{key}' ~/.ssh/authorized_keys || echo '{key}' >> ~/.ssh/authorized_keys) && echo Relaya: key installed";
        MainWindow.Current?.OpenSession(alias, command + "\r");
    }

    private async Task Create()
    {
        var name = new TextBox { Header = L("Имя файла"), Text = "id_ed25519" };
        var comment = new TextBox { Header = L("Комментарий"), Text = System.Environment.UserName + "@" + System.Environment.MachineName };
        var pass = new PasswordBox { Header = L("Пароль ключа (необязательно)") };
        var error = Ui.Secondary("");
        var d = new ContentDialog
        {
            Title = L("Новый ключ ed25519"),
            Content = new StackPanel { Spacing = 12, MinWidth = 380, Children = { name, comment, pass, error } },
            PrimaryButtonText = L("Создать"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        d.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            var file = Path.Combine(AppState.SshDir, name.Text.Trim());
            if (name.Text.Trim().Length == 0 || File.Exists(file)) { error.Text = L("Файл уже есть или имя пустое."); args.Cancel = true; deferral.Complete(); return; }
            Directory.CreateDirectory(AppState.SshDir);
            // Passphrase — вводом в псевдотерминал, не аргументом ssh-keygen (виден был бы в списке процессов).
            var (ok, err) = await Platform.KeyGen.CreateAsync(file, comment.Text, pass.Password);
            if (!ok) { error.Text = err; args.Cancel = true; }
            deferral.Complete();
        };
        if (await d.ShowAsync() == ContentDialogResult.Primary) await Build();
    }
}
