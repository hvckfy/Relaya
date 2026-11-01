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
    // UI-очередь снимается в конструкторе (UI-поток). События приходят из фоновых потоков (ConPTY, туннели,
    // синхронизация), а свойство DispatcherQueue XAML-объекта из чужого потока в C# падает InvalidCastException.
    private readonly Microsoft.UI.Dispatching.DispatcherQueue ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();

    public static MainWindow? Current { get; private set; }

    /// Handle окна, снятый в UI-потоке: им пользуются фоновые потоки (Windows Hello для askpass).
    public static IntPtr Hwnd { get; private set; }

    public MainWindow()
    {
        InitializeComponent();
        // Без переходной анимации: страница не «въезжает» справа (и не застревает за краем при двойном клике
        // по хосту, когда сразу открывается вкладка) — показывается сразу, как в Параметрах Windows.
        Page.ContentTransitions = new Microsoft.UI.Xaml.Media.Animation.TransitionCollection();
        // Вкладку можно перетащить на край терминала другой вкладки — режим плиток.
        Tabs.CanDragTabs = true;
        Tabs.TabDragStarting += (_, e) =>
        {
            DraggedTiles = (e.Tab.Tag as Tab)?.Content as Terminal.TileHost;
            // Нажатие на вкладку уже выбрало её, и на экране её же плитки — бросить некуда. Показываем вкладку,
            // открытую до нажатия: на неё и перетаскивают.
            if (Tabs.SelectedItem == e.Tab && previousTab != null && Tabs.TabItems.Contains(previousTab)) Tabs.SelectedItem = previousTab;
            e.Data.SetText("relaya-tab");
            e.Data.RequestedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move;
        };
        Tabs.TabDragCompleted += (_, _) => DraggedTiles = null;
        TabHost.ChildrenTransitions = new Microsoft.UI.Xaml.Media.Animation.TransitionCollection();
        Nav.ContentTransitions = new Microsoft.UI.Xaml.Media.Animation.TransitionCollection();
        Current = this;
#if !HAS_UNO
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        // Windows: вкладки в заголовке, как в Windows Terminal. Linux: заголовок и кнопки окна рисует система (GNOME HIG, SSD).
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Relaya.ico"));
#endif
        Title = "Relaya";
        RestoreBounds();
        ApplyTheme();
        AddShortcuts();
        ConfigPath.Text = AppState.ConfigPath;
        // Не хватает обязательного компонента (Linux: ssh, libsecret, хранилище паролей) — сказать на стартовом экране (Л5).
        if (Platform.Components.List().Any(c => c.Required && !c.Found))
        {
            var open = new Button { Content = L("Компоненты") };
            open.Click += (_, _) => ShowPage(Pages.ComponentsPage.Build());
            Empty.Children.Insert(0, new InfoBar
            {
                Severity = InfoBarSeverity.Warning, IsOpen = true, IsClosable = true, MaxWidth = 560, Margin = new Thickness(0, 0, 0, 16),
                Title = L("Не хватает обязательных компонентов"), Message = L("Без них часть Relaya не работает. Что поставить и как — в «Компонентах»."),
                ActionButton = open,
            });
        }
        Search.PlaceholderText = L("Поиск хостов");
        NewHostText.Text = L("Новый хост…");
        AppState.HostsChanged += () => ui.TryEnqueue(() => Render(Search.Text.Trim()));
        AppState.LoadHosts();
        Platform.SyncService.Shared.Imported += () => ui.TryEnqueue(AppState.LoadHosts);
        Platform.SyncService.Shared.AgentEscalationsPending += list =>
            ui.TryEnqueue(() => { if (Content?.XamlRoot is { } root) _ = Relaya.Settings.AgentEscalationsDialog.Show(root, list); });
        Platform.SyncService.Shared.DeletionsPending += pending =>
            ui.TryEnqueue(() => { if (Content?.XamlRoot is { } root) _ = Relaya.Settings.DeletionsDialog.Show(root, pending); });
        Platform.SyncService.Shared.ScheduleAuto();
        Platform.TunnelManager.Shared.StartAuto();
        Closed += (_, _) => Platform.TunnelManager.Shared.StopAll();
        // Свёрнутые группы запоминаются, как на Mac.
        Nav.Expanding += (_, a) => { if (a.ExpandingItemContainer?.Tag is string t && t.StartsWith("group:")) Platform.Settings.Set(t.Replace("group:", "group."), "1"); };
        Nav.Collapsed += (_, a) => { if (a.CollapsedItemContainer?.Tag is string t && t.StartsWith("group:")) Platform.Settings.Set(t.Replace("group:", "group."), "0"); };
    }

    // Размер и позиция окна запоминаются (UI-W1): window.bounds = x,y,w,h в физических пикселях. Если сохранённое
    // место вне экранов (монитор отключили), окно открывается по центру рабочей области. Минимум — 800×560.
    private void RestoreBounds()
    {
        var saved = Platform.Settings.Get("window.bounds", "").Split(',');
        var rect = new Windows.Graphics.RectInt32 { X = 0, Y = 0, Width = 1280, Height = 820 };
        var restored = saved.Length == 4 && int.TryParse(saved[0], out rect.X) && int.TryParse(saved[1], out rect.Y)
            && int.TryParse(saved[2], out rect.Width) && int.TryParse(saved[3], out rect.Height) && rect.Width >= 400 && rect.Height >= 300;
#if !HAS_UNO
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter p) { p.PreferredMinimumWidth = 800; p.PreferredMinimumHeight = 560; }
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromRect(rect, Microsoft.UI.Windowing.DisplayAreaFallback.None);
        if (restored && area != null) AppWindow.MoveAndResize(rect);
        else
        {
            var work = Microsoft.UI.Windowing.DisplayArea.Primary.WorkArea;
            AppWindow.MoveAndResize(new Windows.Graphics.RectInt32
            {
                X = work.X + Math.Max(0, (work.Width - rect.Width) / 2), Y = work.Y + Math.Max(0, (work.Height - rect.Height) / 2),
                Width = Math.Min(rect.Width, work.Width), Height = Math.Min(rect.Height, work.Height),
            });
        }
        AppWindow.Changed += (w, e) =>
        {
            if (!(e.DidSizeChange || e.DidPositionChange) || w.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: not Microsoft.UI.Windowing.OverlappedPresenterState.Restored })
                return;
            Platform.Settings.Set("window.bounds", $"{w.Position.X},{w.Position.Y},{w.Size.Width},{w.Size.Height}");
        };
#else
        AppWindow.Resize(new Windows.Graphics.SizeInt32 { Width = rect.Width, Height = rect.Height });
#endif
    }

    /// Группы из ~/.ssh/config — настройки синхронизации отличают по ним группы от хостов.
    public static HashSet<string> KnownGroups() => AppState.Groups().ToHashSet();

    private async void OnNewHost(object sender, RoutedEventArgs e) => await Pages.HostEditor.Show(Content.XamlRoot, null, false);

    // Сайдбар как на Mac: «Хосты» со сворачиваемыми группами, «Удалённые столы», «Инструменты».
    // Фильтр по метке (1.7): одна метка, «Все хосты» — сброс. Кнопка рядом с заголовком «Хосты».
    private string? tagFilter;

    private UIElement HostsHeader()
    {
        var tags = AppState.Hosts.SelectMany(h => h.tags).Distinct().OrderBy(t => t).ToList();
        var title = new TextBlock { Text = tagFilter == null ? L("Хосты") : L("Хосты · #%@", tagFilter), VerticalAlignment = VerticalAlignment.Center };
        if (tags.Count == 0) return title;
        var menu = new MenuFlyout();
        var all = new ToggleMenuFlyoutItem { Text = L("Все хосты"), IsChecked = tagFilter == null };
        all.Click += (_, _) => { tagFilter = null; Render(Search.Text.Trim()); };
        menu.Items.Add(all);
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var t in tags)
        {
            var item = new ToggleMenuFlyoutItem { Text = "#" + t, IsChecked = tagFilter == t };
            item.Click += (_, _) => { tagFilter = t; Render(Search.Text.Trim()); };
            menu.Items.Add(item);
        }
        var button = new Button
        {
            Content = new FontIcon { Glyph = "\uE71C", FontSize = Pages.Ui.IconSmall }, Flyout = menu, Padding = new Thickness(4),
            Background = Pages.Ui.Brush("SubtleFillColorTransparentBrush"), BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(button, L("Фильтр по меткам"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, L("Фильтр по меткам"));
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { title, button } };
    }

    private void Render(string query)
    {
        EmptyTitle.Text = AppState.Hosts.Count == 0 ? L("Хостов пока нет — добавьте первый кнопкой «Новый хост…»") : L("Выберите хост слева");
        Nav.MenuItems.Clear();
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = HostsHeader() });
        var shown = AppState.Hosts.Where(h => (query.Length == 0
            || RelayaCoreMethods.FuzzyScoreFields(query, Fields(h)) != null) && (tagFilter == null || h.tags.Contains(tagFilter)));
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
            // Группы столов и контекстное меню (Е.13): подключить, внешний клиент, изменить, удалить.
            NavigationViewItem DesktopItem(RemoteDesktop d)
            {
                var item = new NavigationViewItem { Content = d.name, Tag = d, Icon = new FontIcon { Glyph = d.kind == DesktopKind.Rdp ? "" : "" } };
                var menu = new MenuFlyout();
                void Add(string text, Action act) { var mi = new MenuFlyoutItem { Text = text }; mi.Click += (_, _) => act(); menu.Items.Add(mi); }
                Add(L("Подключить"), () => Platform.DesktopLauncher.Open(d, Content.XamlRoot));
                Add(d.kind == DesktopKind.Rdp ? Platform.PlatformText.ExternalRdp() : Platform.PlatformText.ExternalVnc(),
                    () => _ = Platform.DesktopLauncher.OpenExternal(d, Content.XamlRoot));
                menu.Items.Add(new MenuFlyoutSeparator());
                Add(L("Изменить…"), () => ShowPage(new Pages.DesktopsPage(d.id)));
                Add(L("Удалить…"), () => _ = Pages.DesktopsPage.DeleteAsync(d, Content.XamlRoot));
                item.ContextFlyout = menu;
                return item;
            }
            foreach (var group in desktops.GroupBy(d => d.group ?? "").OrderBy(g => g.Key.Length == 0 ? "" : "~" + g.Key))
            {
                if (group.Key.Length == 0) { foreach (var d in group) Nav.MenuItems.Add(DesktopItem(d)); continue; }
                var folder = new NavigationViewItem { Content = group.Key, Icon = new FontIcon { Glyph = "\uE8B7" }, SelectsOnInvoked = false, IsExpanded = true };
                foreach (var d in group) folder.MenuItems.Add(DesktopItem(d));
                Nav.MenuItems.Add(folder);
            }
        }
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = L("Инструменты") });
        Nav.MenuItems.Add(Tool("keys", L("Ключи"), ""));
        Nav.MenuItems.Add(Tool("tunnels", L("Туннели"), ""));
        Nav.MenuItems.Add(Tool("layouts", L("Раскладки"), "\ue8a9"));
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
        // Цвет хоста — точкой после имени (Е.10).
        if (Pages.HostColors.Of(h.color) is { } dot)
            item.Content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 8,
                Children =
                {
                    new TextBlock { Text = h.alias },
                    new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center, Fill = new Microsoft.UI.Xaml.Media.SolidColorBrush(dot) },
                },
            };
        ToolTipService.SetToolTip(item, RelayaCoreMethods.HostSubtitle(h));
        item.ContextFlyout = Pages.HostActions.Menu(h, item);
        // Handled: иначе фокус остаётся у пункта списка, а не у новой плитки (Л3).
        item.DoubleTapped += (_, e) =>
        {
            e.Handled = true;
            openedByDoubleTap = (h.alias, Environment.TickCount64);
            OpenSession(h.alias);
        };
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
            // Второй щелчок двойного клика тоже приходит как ItemInvoked — не уводим с только что открытого терминала.
            case SshHost h when openedByDoubleTap is { } t && t.Alias == h.alias && Environment.TickCount64 - t.At < 700: break;
            case SshHost h: ShowPage(new Pages.HostPage(h)); break;
            case RemoteDesktop d: Platform.DesktopLauncher.Open(d, Content.XamlRoot); break;
            case "keys": ShowPage(new Pages.KeysPage()); break;
            case "tunnels": ShowPage(new Pages.TunnelsPage()); break;
            case "snippets": ShowPage(new Pages.SnippetsPage()); break;
            case "layouts": ShowPage(new Pages.LayoutsPage()); break;
            case "desktops": ShowPage(new Pages.DesktopsPage()); break;
            case "agents": ShowPage(new Pages.AgentsPage()); break;
        }
    }

    private Pages.SettingsPage? settingsPage;
    private (string Alias, long At)? openedByDoubleTap;

    /// Пустая область «Выберите хост слева» (например, отмена «Нового хоста»).
    internal void ShowNothing()
    {
        Tabs.SelectedItem = null;
        Show(null);
    }

    /// Страница слева-справа (карточка хоста, ключи…): снимает выбор вкладки.
    public void ShowPage(UIElement page)
    {
        Tabs.SelectedItem = null;
        Show(page);
    }

    private void Show(UIElement? page)
    {
        // Вкладки не вынимаются из дерева (иначе Win2D теряет Canvas) — показывается одна, остальные свёрнуты.
        var tab = page != null && TabHost.Children.Contains(page);
        foreach (var c in TabHost.Children) c.Visibility = c == page ? Visibility.Visible : Visibility.Collapsed;
        Page.Content = tab ? null : page;
        Page.Visibility = tab ? Visibility.Collapsed : Visibility.Visible;
        Empty.Visibility = page is null ? Visibility.Visible : Visibility.Collapsed;
    }

    // --- Вкладки: терминалы (с плитками) и SFTP. Вкладка в заголовке, содержимое — в основной области. ---

    public void OpenSession(string alias, string? initialInput = null)
    {
        var tiles = new Terminal.TileHost();
        var tab = AddTab(alias, "", tiles, tiles);
        if (Pages.HostColors.Of(AppState.Host(alias)?.color) is { } tint && tab.IconSource is FontIconSource icon)
            icon.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(tint);
        tiles.TitleChanged += t => ui.TryEnqueue(() => tab.Header = t);
        tiles.AliveChanged += alive => ui.TryEnqueue(() =>
            tab.IconSource = new FontIconSource
            {
                Glyph = alive ? "" : "",
                Foreground = Pages.HostColors.Of(AppState.Host(alias)?.color) is { } c ? new Microsoft.UI.Xaml.Media.SolidColorBrush(c) : null,
            });
        tiles.Add(alias, initialInput);
        // Контекстное меню вкладки: разделить — та же сессия рядом (как Ctrl+Shift+D/E).
        var menu = new MenuFlyout();
        var right = new MenuFlyoutItem { Text = L("Разделить вправо"), KeyboardAcceleratorTextOverride = "Ctrl+Shift+D" };
        right.Click += (_, _) => tiles.Split(uniffi.relaya_core.Edge.Right);
        var down = new MenuFlyoutItem { Text = L("Разделить вниз"), KeyboardAcceleratorTextOverride = "Ctrl+Shift+E" };
        down.Click += (_, _) => tiles.Split(uniffi.relaya_core.Edge.Bottom);
        menu.Items.Add(right);
        menu.Items.Add(down);
        menu.Items.Add(new MenuFlyoutSeparator());
        var save = new MenuFlyoutItem { Text = L("Сохранить раскладку…") };
        save.Click += async (_, _) => await SaveLayout(tiles);
        menu.Items.Add(save);
        tab.ContextFlyout = menu;
        // Фокус в терминал после того, как вкладка выбрана и список хостов отпустил фокус (на Uno Loaded мало, Л3).
        ui.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, tiles.FocusActive);
    }

    private async System.Threading.Tasks.Task SaveLayout(Terminal.TileHost tiles)
    {
        if (tiles.SaveableLayout() is not { } layout) return;
        var name = new TextBox { Header = L("Название"), PlaceholderText = L("Мои серверы") };
        var dialog = new ContentDialog
        {
            Title = L("Сохранить раскладку"), Content = name, PrimaryButtonText = L("Сохранить"), CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary, XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || name.Text.Trim().Length == 0) return;
        SavedLayouts.Add(name.Text.Trim(), layout);
    }

    /// Открыть сохранённую раскладку одной вкладкой с плитками.
    internal void OpenLayout(SavedLayouts.Saved saved)
    {
        var tiles = new Terminal.TileHost();
        var tab = AddTab(saved.Name, "\ue8a9", tiles, tiles);
        tiles.TitleChanged += t => ui.TryEnqueue(() => tab.Header = saved.Name + " — " + t);
        if (!tiles.Open(saved.Layout)) CloseTab(tab);
    }

    /// Вкладка с плитками, которую сейчас перетаскивают (TabView → холст другой вкладки).
    internal static Terminal.TileHost? DraggedTiles;

    /// Плитки вкладки переехали в другую — закрыть опустевшую вкладку.
    /// Закрыть вкладку с этим содержимым (плитки, переехавшие в другую вкладку; окно tmux, закрытое на сервере).
    internal void CloseTabOf(UIElement content)
    {
        if (Tabs.TabItems.OfType<TabViewItem>().FirstOrDefault(t => (t.Tag as Tab)?.Content == content) is { } tab) CloseTab(tab);
    }

    public void OpenSftp(string alias)
    {
        var page = new Pages.SftpPage(alias);
        AddTab(L("Файлы: %@", alias), "", page, null);
    }

    /// Вкладка с произвольным содержимым (удалённый стол и т. п.); owner закрывается вместе с вкладкой
    /// (если null, а содержимое — IDisposable, закрывается оно само).
    public void OpenTab(string title, string glyph, UIElement content, IDisposable? owner) =>
        AddTab(title, glyph, content, owner ?? content as IDisposable);

    private TabViewItem AddTab(string title, string glyph, UIElement content, IDisposable? owner)
    {
        var tab = new TabViewItem
        {
            Header = title, IconSource = new FontIconSource { Glyph = glyph }, Tag = new Tab(content, owner),
        };
        content.Visibility = Visibility.Collapsed;
        TabHost.Children.Add(content);
        Tabs.TabItems.Add(tab);
        Tabs.SelectedItem = tab;
        return tab;
    }

    private sealed record Tab(UIElement Content, IDisposable? Owner);

    /// tmux-сессии всех открытых вкладок: уборка старых сессий их не трогает (К10).
    internal List<string> OpenTmuxNames => Tabs.TabItems.OfType<TabViewItem>()
        .Select(t => (t.Tag as Tab)?.Content).OfType<Terminal.TileHost>().SelectMany(t => t.TmuxNames).ToList();

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

    // Вкладка, выбранная до последнего переключения, — цель перетаскивания вкладки на плитки.
    private TabViewItem? previousTab;

    private void OnTabSelected(object sender, SelectionChangedEventArgs e)
    {
        if (e.RemovedItems.Count > 0 && e.RemovedItems[0] is TabViewItem removed) previousTab = removed;
        if ((Tabs.SelectedItem as TabViewItem)?.Tag is Tab t)
        {
            Nav.SelectedItem = null;
            Show(t.Content);
        }
        else if (Page.Visibility == Visibility.Collapsed)
        {
            Show(null);
        }
    }

    private void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args) => CloseTab(args.Tab);

    private void CloseTab(TabViewItem tab)
    {
        if (tab.Tag is Tab t) { t.Owner?.Dispose(); TabHost.Children.Remove(t.Content); }
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

    // Сочетания как на Mac (⌘ → Ctrl+Shift, где Ctrl+буква нужна shell): Ctrl+Shift+N — новый хост, F2 — изменить,
    // F5 — перечитать ~/.ssh/config, Ctrl+Shift+T — новая вкладка к хосту, Ctrl+Shift+R — переподключить,
    // Ctrl+Shift+O — файлы хоста, Ctrl+Alt+1…9 — вкладка по номеру.
    private SshHost? CurrentHost()
    {
        if (Page.Content is Pages.HostPage hp) return hp.Host;
        var alias = ((Tabs.SelectedItem as TabViewItem)?.Tag as Tab)?.Content is Terminal.TileHost t ? t.ActiveAlias : null;
        return alias != null ? AppState.Host(alias) : null;
    }

    /// Тема окна из настройки app.theme (system | light | dark).
    internal void ApplyTheme()
    {
        if (Content is FrameworkElement root)
            root.RequestedTheme = Platform.Settings.Get("app.theme", "system") switch
            {
                "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default,
            };
    }

    private void AddShortcuts()
    {
        void Add(Windows.System.VirtualKey key, Windows.System.VirtualKeyModifiers mods, Action action)
        {
            var a = new KeyboardAccelerator { Key = key, Modifiers = mods };
            a.Invoked += (_, e) => { e.Handled = true; action(); };
            ((UIElement)Content).KeyboardAccelerators.Add(a);
        }
        var cs = Windows.System.VirtualKeyModifiers.Control | Windows.System.VirtualKeyModifiers.Shift;
        var none = Windows.System.VirtualKeyModifiers.None;
        Add(Windows.System.VirtualKey.N, cs, () => _ = Pages.HostEditor.Show(Content.XamlRoot, null, false));
        Add(Windows.System.VirtualKey.F2, none, () => { if (CurrentHost() is { } h) _ = Pages.HostEditor.Show(Content.XamlRoot, h, false); });
        Add(Windows.System.VirtualKey.F5, none, AppState.LoadHosts);
        Add(Windows.System.VirtualKey.T, cs, () => { if (CurrentHost() is { } h) OpenSession(h.alias); });
        Add(Windows.System.VirtualKey.O, cs, () => { if (CurrentHost() is { } h) OpenSftp(h.alias); });
        Add(Windows.System.VirtualKey.R, cs, () =>
        {
            if (((Tabs.SelectedItem as TabViewItem)?.Tag as Tab)?.Content is Terminal.TileHost t) t.ReconnectActive();
        });
        for (var i = 1; i <= 9; i++)
        {
            var index = i - 1;
            Add(Windows.System.VirtualKey.Number0 + i, Windows.System.VirtualKeyModifiers.Control | Windows.System.VirtualKeyModifiers.Menu,
                () => { if (index < Tabs.TabItems.Count) Tabs.SelectedIndex = index; });
        }
    }

    private void OnCloseTabKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; CloseActiveTab(); }
    private void OnNextTabKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; NextTab(1); }
    private void OnPrevTabKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; NextTab(-1); }
    private void OnSearchKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; FocusSearch(); }
    private void OnPaletteKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; Pages.CommandPalette.Show(this); }

    public void FocusSearch() => Search.Focus(FocusState.Keyboard);
}
