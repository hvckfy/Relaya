using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.relaya_core;

namespace Relaya;

public sealed partial class MainWindow : Window
{
    private static readonly string SshConfig =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "config");

    private List<SshHost> hosts = new();

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        ConfigPath.Text = SshConfig;
        LoadHosts();
    }

    // ~/.ssh/config — источник правды, как на Mac; разбирает общее Rust-ядро.
    private void LoadHosts()
    {
        var text = File.Exists(SshConfig) ? File.ReadAllText(SshConfig) : "";
        hosts = RelayaCoreMethods.ParseConfig(text)
            .Where(h => !RelayaCoreMethods.IsPattern(h.alias) && !RelayaCoreMethods.HostIsGitService(h))
            .ToList();
        Render("");
        EmptyTitle.Text = hosts.Count == 0 ? "Хостов пока нет — добавьте первый кнопкой «Новый хост…»" : "Выберите хост слева";
    }

    // Новый хост пишется в ~/.ssh/config тем же кодом ядра, что и на Mac.
    private async void OnNewHost(object sender, RoutedEventArgs e)
    {
        TextBox Field(string header, string placeholder) => new() { Header = header, PlaceholderText = placeholder };
        var alias = Field("Название (Host)", "prod-web");
        var address = Field("Адрес (HostName)", "203.0.113.10 или server.example.com");
        var user = Field("Пользователь", "root");
        var port = Field("Порт", "22");
        var key = Field("Ключ (IdentityFile)", "~/.ssh/id_ed25519 — необязательно");
        var group = Field("Группа", "необязательно");
        var error = new TextBlock { Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.IndianRed), TextWrapping = TextWrapping.Wrap };
        var dialog = new ContentDialog
        {
            Title = "Новый хост",
            Content = new ScrollViewer { Content = new StackPanel { Spacing = 10, Children = { alias, address, user, port, key, group, error } } },
            PrimaryButtonText = "Добавить",
            CloseButtonText = "Отмена",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot,
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            string? Opt(TextBox b) => string.IsNullOrWhiteSpace(b.Text) ? null : b.Text.Trim();
            if (Opt(alias) is not { } name || name.Contains(' ')) { error.Text = "Укажите название без пробелов."; args.Cancel = true; return; }
            long? portValue = null;
            if (Opt(port) is { } p)
            {
                if (!long.TryParse(p, out var v) || v is < 1 or > 65535) { error.Text = "Порт — число от 1 до 65535."; args.Cancel = true; return; }
                portValue = v;
            }
            var host = new SshHost(name, Opt(address), Opt(user), portValue, Opt(key), null, null, null, null, Opt(group),
                new List<string>(), null, null, false);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(SshConfig)!);
                var text = File.Exists(SshConfig) ? File.ReadAllText(SshConfig) : "";
                File.WriteAllText(SshConfig, RelayaCoreMethods.ConfigUpsert(text, host, null));
            }
            catch (Exception ex)
            {
                error.Text = ex.Message;
                args.Cancel = true;
            }
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) LoadHosts();
    }

    // Секции и группы — как сайдбар на Mac: «Хосты», внутри сворачиваемые группы.
    private void Render(string query)
    {
        Nav.MenuItems.Clear();
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = "Хосты" });
        var shown = hosts.Where(h => query.Length == 0
            || h.alias.Contains(query, StringComparison.OrdinalIgnoreCase)
            || (h.hostName ?? "").Contains(query, StringComparison.OrdinalIgnoreCase));
        foreach (var group in shown.GroupBy(h => h.group ?? ""))
        {
            var items = group.Select(HostItem).ToList();
            if (group.Key.Length == 0)
            {
                items.ForEach(Nav.MenuItems.Add);
                continue;
            }
            var folder = new NavigationViewItem
            {
                Content = group.Key, Icon = new FontIcon { Glyph = "" }, SelectsOnInvoked = false,
                IsExpanded = true,
            };
            items.ForEach(folder.MenuItems.Add);
            Nav.MenuItems.Add(folder);
        }
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = "Инструменты" });
        Nav.MenuItems.Add(new NavigationViewItem { Content = "Ключи", Icon = new FontIcon { Glyph = "" } });
        Nav.MenuItems.Add(new NavigationViewItem { Content = "Туннели", Icon = new FontIcon { Glyph = "" } });
        Nav.MenuItems.Add(new NavigationViewItem { Content = "Сниппеты", Icon = new FontIcon { Glyph = "" } });
    }

    private static async System.Threading.Tasks.Task AskPassword(FrameworkElement anchor, string alias)
    {
        var box = new PasswordBox { PlaceholderText = "Пароль" };
        var dialog = new ContentDialog
        {
            Title = $"Пароль для {alias}",
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    box,
                    new TextBlock
                    {
                        Text = "Хранится в диспетчере учётных данных Windows и вводится сам, когда сервер спросит пароль.",
                        TextWrapping = TextWrapping.Wrap,
                        Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                    },
                },
            },
            PrimaryButtonText = "Сохранить",
            CloseButtonText = "Отмена",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = anchor.XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && box.Password.Length > 0)
            Platform.CredentialStore.Write(alias, box.Password);
    }

    private static NavigationViewItem HostItem(SshHost h)
    {
        var item = new NavigationViewItem { Content = h.alias, Tag = h, Icon = new FontIcon { Glyph = "" } };
        ToolTipService.SetToolTip(item, RelayaCoreMethods.HostSubtitle(h));
        var menu = new MenuFlyout();
        var save = new MenuFlyoutItem { Text = "Сохранить пароль…", Icon = new FontIcon { Glyph = "\uE8D7" } };
        save.Click += async (_, _) => await AskPassword(item, h.alias);
        var forget = new MenuFlyoutItem { Text = "Забыть пароль", Icon = new FontIcon { Glyph = "\uE74D" } };
        forget.Click += (_, _) => Platform.CredentialStore.Delete(h.alias);
        menu.Opening += (_, _) => forget.IsEnabled = Platform.CredentialStore.Has(h.alias);
        menu.Items.Add(save);
        menu.Items.Add(forget);
        item.ContextFlyout = menu;
        return item;
    }

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) =>
        Render(sender.Text.Trim());

    private void OnItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer?.Tag is not SshHost h) return;
        var view = new Terminal.TerminalView();
        var session = new Terminal.SshSession(view, h.alias);
        var tab = new TabViewItem
        {
            Header = h.alias,
            IconSource = new FontIconSource { Glyph = "\uE756" },
            Content = view,
            Tag = session,
        };
        Tabs.TabItems.Add(tab);
        Tabs.SelectedItem = tab;
        // Размер в ячейках известен после первой раскладки — тогда и запускаем ssh.
        session.StateChanged += alive => DispatcherQueue.TryEnqueue(() =>
            tab.IconSource = new FontIconSource { Glyph = alive ? "\uE756" : "\uE783" });
        var started = false;
        view.Loaded += (_, _) =>
        {
            if (!started) { started = true; session.Start(); }
            view.Focus(FocusState.Programmatic);
        };
    }

    private void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        (args.Tab.Tag as IDisposable)?.Dispose();
        sender.TabItems.Remove(args.Tab);
    }
}
