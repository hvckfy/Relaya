using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya;

public sealed partial class MainWindow : Window
{
    public static MainWindow? Current { get; private set; }

    public MainWindow()
    {
        InitializeComponent();
        Current = this;
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        Title = "Relaya";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 820));
        ConfigPath.Text = AppState.ConfigPath;
        Search.PlaceholderText = L("Поиск хостов");
        NewHostText.Text = L("Новый хост…");
        AppState.HostsChanged += () => DispatcherQueue.TryEnqueue(() => Render(Search.Text.Trim()));
        AppState.LoadHosts();
        Platform.SyncService.Shared.Imported += () => DispatcherQueue.TryEnqueue(AppState.LoadHosts);
        Platform.SyncService.Shared.ScheduleAuto();
        Platform.TunnelManager.Shared.StartAuto();
        Closed += (_, _) => Platform.TunnelManager.Shared.StopAll();
        // Свёрнутые группы запоминаются, как на Mac.
        Nav.Expanding += (_, a) => { if (a.ExpandingItemContainer?.Tag is string t && t.StartsWith("group:")) Platform.Settings.Set(t.Replace("group:", "group."), "1"); };
        Nav.Collapsed += (_, a) => { if (a.CollapsedItemContainer?.Tag is string t && t.StartsWith("group:")) Platform.Settings.Set(t.Replace("group:", "group."), "0"); };
    }

    /// Группы из ~/.ssh/config — настройки синхронизации отличают по ним группы от хостов.
    public static HashSet<string> KnownGroups() => AppState.Groups().ToHashSet();

    private async void OnNewHost(object sender, RoutedEventArgs e) => await Pages.HostEditor.Show(Content.XamlRoot, null, false);

    // Сайдбар как на Mac: «Хосты» со сворачиваемыми группами, «Удалённые столы», «Инструменты».
    private void Render(string query)
    {
        EmptyTitle.Text = AppState.Hosts.Count == 0 ? L("Хостов пока нет — добавьте первый кнопкой «Новый хост…»") : L("Выберите хост слева");
        Nav.MenuItems.Clear();
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = L("Хосты") });
        var shown = AppState.Hosts.Where(h => query.Length == 0
            || RelayaCoreMethods.FuzzyScoreFields(query, Fields(h)) != null);
        foreach (var group in shown.GroupBy(h => h.group ?? "").OrderBy(g => g.Key.Length == 0 ? "" : "~" + g.Key))
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
                IsExpanded = Platform.Settings.Get("group." + group.Key, "1") == "1",
            };
            folder.Tag = "group:" + group.Key;
            items.ForEach(folder.MenuItems.Add);
            Nav.MenuItems.Add(folder);
        }
        var desktops = AppState.Desktops;
        if (desktops.Count > 0)
        {
            Nav.MenuItems.Add(new NavigationViewItemHeader { Content = L("Удалённые столы") });
            foreach (var d in desktops)
                Nav.MenuItems.Add(new NavigationViewItem
                {
                    Content = d.name, Tag = d, Icon = new FontIcon { Glyph = d.kind == DesktopKind.Rdp ? "" : "" },
                });
        }
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = L("Инструменты") });
        Nav.MenuItems.Add(Tool("keys", L("Ключи"), ""));
        Nav.MenuItems.Add(Tool("tunnels", L("Туннели"), ""));
        Nav.MenuItems.Add(Tool("snippets", L("Сниппеты"), ""));
        Nav.MenuItems.Add(Tool("desktops", L("Удалённые столы"), ""));
        Nav.MenuItems.Add(Tool("agents", L("Агенты"), ""));
    }

    private static List<string> Fields(SshHost h) =>
        new[] { h.alias, h.hostName ?? "", h.user ?? "", h.group ?? "" }.Concat(h.tags).ToList();

    private static NavigationViewItem Tool(string tag, string title, string glyph) =>
        new() { Content = title, Tag = tag, Icon = new FontIcon { Glyph = glyph } };

    private NavigationViewItem HostItem(SshHost h)
    {
        var item = new NavigationViewItem { Content = h.alias, Tag = h, Icon = Pages.OsIcon.For(h.os) };
        ToolTipService.SetToolTip(item, RelayaCoreMethods.HostSubtitle(h));
        item.ContextFlyout = Pages.HostActions.Menu(h, item);
        item.DoubleTapped += (_, _) => OpenSession(h.alias);
        return item;
    }

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) => Render(sender.Text.Trim());

    // Enter в поиске — подключиться к первому найденному, как ⌘K на Mac.
    private void OnSearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        var first = AppState.Hosts.Select(h => (h, s: RelayaCoreMethods.FuzzyScoreFields(sender.Text.Trim(), Fields(h))))
            .Where(x => x.s != null).OrderByDescending(x => x.s).Select(x => x.h).FirstOrDefault();
        if (first != null) OpenSession(first.alias);
    }

    private void OnItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.IsSettingsInvoked) { ShowPage(settingsPage ??= new Pages.SettingsPage()); return; }
        switch (args.InvokedItemContainer?.Tag)
        {
            case SshHost h: ShowPage(new Pages.HostPage(h)); break;
            case RemoteDesktop d: Platform.DesktopLauncher.Open(d, Content.XamlRoot); break;
            case "keys": ShowPage(new Pages.KeysPage()); break;
            case "tunnels": ShowPage(new Pages.TunnelsPage()); break;
            case "snippets": ShowPage(new Pages.SnippetsPage()); break;
            case "desktops": ShowPage(new Pages.DesktopsPage()); break;
            case "agents": ShowPage(new Pages.AgentsPage()); break;
        }
    }

    private Pages.SettingsPage? settingsPage;

    /// Страница слева-справа (карточка хоста, ключи…): снимает выбор вкладки.
    public void ShowPage(UIElement page)
    {
        Tabs.SelectedItem = null;
        Show(page);
    }

    private void Show(UIElement? page)
    {
        Page.Content = page;
        Empty.Visibility = page is null ? Visibility.Visible : Visibility.Collapsed;
    }

    // --- Вкладки: терминалы (с плитками) и SFTP. Вкладка в заголовке, содержимое — в основной области. ---

    public void OpenSession(string alias, string? initialInput = null)
    {
        var tiles = new Terminal.TileHost();
        var tab = AddTab(alias, "", tiles, tiles);
        tiles.TitleChanged += t => DispatcherQueue.TryEnqueue(() => tab.Header = t);
        tiles.AliveChanged += alive => DispatcherQueue.TryEnqueue(() =>
            tab.IconSource = new FontIconSource { Glyph = alive ? "" : "" });
        tiles.Add(alias, initialInput);
    }

    public void OpenSftp(string alias)
    {
        var page = new Pages.SftpPage(alias);
        AddTab(L("Файлы: %@", alias), "", page, null);
    }

    private TabViewItem AddTab(string title, string glyph, UIElement content, IDisposable? owner)
    {
        var tab = new TabViewItem
        {
            Header = title, IconSource = new FontIconSource { Glyph = glyph }, Tag = new Tab(content, owner),
        };
        Tabs.TabItems.Add(tab);
        Tabs.SelectedItem = tab;
        return tab;
    }

    private sealed record Tab(UIElement Content, IDisposable? Owner);

    /// Терминал активной вкладки — для сниппетов и действий ОС.
    internal Terminal.TerminalView? ActiveTerminal =>
        ((Tabs.SelectedItem as TabViewItem)?.Tag as Tab)?.Content is Terminal.TileHost t ? t.Active : null;

    /// Последняя открытая терминальная вкладка (страница сниппетов закрывает выбор вкладки).
    internal Terminal.TerminalView? LastTerminal => Tabs.TabItems.OfType<TabViewItem>().Reverse()
        .Select(t => (t.Tag as Tab)?.Content).OfType<Terminal.TileHost>().Select(t => t.Active).FirstOrDefault();

    internal void SelectTerminal(Terminal.TerminalView view)
    {
        foreach (var t in Tabs.TabItems.OfType<TabViewItem>())
            if ((t.Tag as Tab)?.Content is Terminal.TileHost host && host.Contains(view)) { Tabs.SelectedItem = t; return; }
    }

    private void OnTabSelected(object sender, SelectionChangedEventArgs e)
    {
        if ((Tabs.SelectedItem as TabViewItem)?.Tag is Tab t)
        {
            Nav.SelectedItem = null;
            Show(t.Content);
        }
        else if (Page.Content is Terminal.TileHost or Pages.SftpPage)
        {
            Show(null);
        }
    }

    private void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args) => CloseTab(args.Tab);

    private void CloseTab(TabViewItem tab)
    {
        if (tab.Tag is Tab t) t.Owner?.Dispose();
        Tabs.TabItems.Remove(tab);
        if (Tabs.TabItems.Count == 0) Show(null);
    }

    // Ctrl+T — новая вкладка к хосту из поиска, Ctrl+W — закрыть, Ctrl+Tab — следующая.
    public void CloseActiveTab()
    {
        if (Tabs.SelectedItem is TabViewItem t) CloseTab(t);
    }

    public void NextTab(int delta)
    {
        if (Tabs.TabItems.Count == 0) return;
        var i = Math.Max(0, Tabs.SelectedIndex);
        Tabs.SelectedIndex = (i + delta + Tabs.TabItems.Count) % Tabs.TabItems.Count;
    }

    private void OnCloseTabKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; CloseActiveTab(); }
    private void OnNextTabKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; NextTab(1); }
    private void OnPrevTabKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; NextTab(-1); }
    private void OnSearchKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; FocusSearch(); }

    public void FocusSearch() => Search.Focus(FocusState.Keyboard);
}
