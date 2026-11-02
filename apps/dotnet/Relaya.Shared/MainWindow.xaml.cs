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

    /// true — окно спрятано в трей вместо закрытия; реализация своя у каждой платформы.
    // 8.6, как на Mac: значок в трее виден и хоть один туннель работает — окно прячется, туннели живут;
    // вернуть — щелчок по значку. TrayIcon — у каждой платформы свой (Windows — Shell_NotifyIcon, Linux — StatusNotifierItem).
#if !HAS_UNO
    private Windows.Graphics.RectInt32 passthrough;

    private void UpdateTitleBarPassthrough()
    {
        if (Content?.XamlRoot is not { } root || Tabs.ActualWidth <= 0) return;
        var scale = root.RasterizationScale;
        var origin = Tabs.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
        // Правый край — последняя вкладка (с кнопками прокрутки полосы), а не вся колонка: справа остаётся место для окна.
        var right = origin.X;
        foreach (var item in Tabs.TabItems.OfType<FrameworkElement>())
            if (item.ActualWidth > 0)
                right = Math.Max(right, item.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(item.ActualWidth, 0)).X);
        right = Math.Min(right + 48, origin.X + Tabs.ActualWidth); // запас под кнопки прокрутки и перетаскивание в конец
        var rect = new Windows.Graphics.RectInt32
        {
            X = (int)(origin.X * scale),
            Y = (int)(origin.Y * scale),
            Width = (int)((right - origin.X) * scale),
            Height = (int)(Tabs.ActualHeight * scale),
        };
        if (rect.Equals(passthrough)) return;
        passthrough = rect;
        Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id)
            .SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough, new[] { rect });
    }
#endif

    private bool HideToTray()
    {
        if (!Platform.TrayIcon.Visible) return false;
        var tunnels = AppState.Tunnels.Concat(Platform.TunnelManager.Shared.Temporary);
        if (!tunnels.Any(t => Platform.TunnelManager.Shared.StatusOf(t).State is Platform.TunnelManager.State.Running or Platform.TunnelManager.State.Starting)) return false;
        AppWindow.Hide();
        Platform.TrayIcon.WindowHidden = true;
        return true;
    }

    /// Handle окна, снятый в UI-потоке: им пользуются фоновые потоки (Windows Hello для askpass).
    public static IntPtr Hwnd { get; private set; }

    public MainWindow()
    {
        InitializeComponent();
        // Смена раздела — короткое появление снизу, как в Параметрах Windows. Не сбоку: страница не «въезжает»
        // справа и не застревает за краем при двойном клике по хосту, когда сразу открывается вкладка.
        Page.ContentTransitions = new Microsoft.UI.Xaml.Media.Animation.TransitionCollection
        {
            new Microsoft.UI.Xaml.Media.Animation.EntranceThemeTransition { FromHorizontalOffset = 0, FromVerticalOffset = 28 },
        };
        // Своя полоса вкладок, как на Mac: щелчок выбирает, перетаскивание внутри полосы меняет порядок,
        // а на холст другой вкладки — делает плитки; пока тащат, на экране остаётся текущая вкладка.
        Tabs.SelectionChanged += OnTabSelected;
        Tabs.TabDragStarting += tab => DraggedTiles = (tab.Tag as Tab)?.Content as Terminal.TileHost;
        Tabs.TabDragCompleted += () => DraggedTiles = null;
        TabHost.ChildrenTransitions = new Microsoft.UI.Xaml.Media.Animation.TransitionCollection();
        Nav.ContentTransitions = new Microsoft.UI.Xaml.Media.Animation.TransitionCollection();
        Current = this;
#if !HAS_UNO
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        // Windows: вкладки в заголовке, как в Windows Terminal. Linux: заголовок и кнопки окна рисует система (GNOME HIG, SSD).
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        // Вкладки в заголовке получают мышь (перетаскивание, порядок): их полоса — Passthrough, как в Windows Terminal;
        // окно по-прежнему перетаскивают за пустое место заголовка.
        Tabs.SizeChanged += (_, _) => UpdateTitleBarPassthrough();
        // Новая вкладка и смена её заголовка меняют ширину полосы: пересчёт по размеру самих вкладок, а не каждой раскладки.
        Tabs.TabItems.CollectionChanged += (_, e) =>
        {
            foreach (var tab in e.NewItems?.OfType<FrameworkElement>() ?? Enumerable.Empty<FrameworkElement>())
                tab.SizeChanged += (_, _) => UpdateTitleBarPassthrough();
            DispatcherQueue.TryEnqueue(UpdateTitleBarPassthrough);
        };
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
                Severity = InfoBarSeverity.Warning,
                IsOpen = true,
                IsClosable = true,
                MaxWidth = 560,
                Margin = new Thickness(0, 0, 0, 16),
                Title = L("Не хватает обязательных компонентов"),
                Message = L("Без них часть Relaya не работает. Что поставить и как — в «Компонентах»."),
                ActionButton = open,
            });
        }
        Search.PlaceholderText = L("Поиск хостов");
        NewHostText.Text = L("Новый хост…");
        AppState.HostsChanged += () => ui.TryEnqueue(() => Render(Search.Text.Trim()));
        Platform.Settings.Changed += () => ui.TryEnqueue(ApplyBackground);
        AppState.LoadHosts();
        // --demo --screenshots: a window without a window manager (Xvfb) is never activated, so start on a timer.
        if (Platform.Demo.ScreenshotDir is { } shotsDir)
            ui.TryEnqueue(async () => { await System.Threading.Tasks.Task.Delay(4000); await Platform.DemoScreenshots.RunAsync(this, shotsDir); });
        // Первый запуск — онбординг, когда окно уже на экране (1.15).
        Activated += async (_, _) =>
        {
            if (Content?.XamlRoot is not { } r || onboardingShown) return;
            onboardingShown = true;
            // Demo: no onboarding (the screenshot scenes start below, without waiting for activation).
            if (Platform.Demo.Root != null) return;
            // Другой ContentDialog уже открыт (например, синхронизация спросила об удалениях) — онбординг в следующий раз.
            try { await Pages.OnboardingPage.ShowIfFirstRun(r); }
            catch (System.Runtime.InteropServices.COMException e) { System.Diagnostics.Trace.WriteLine($"Onboarding: {e.Message}"); }
        };
        Platform.SyncService.Shared.Imported += () => ui.TryEnqueue(AppState.LoadHosts);
        Platform.SyncService.Shared.AgentEscalationsPending += list =>
            ui.TryEnqueue(() => { if (Content?.XamlRoot is { } root) _ = Relaya.Settings.AgentEscalationsDialog.Show(root, list); });
        Platform.SyncService.Shared.DeletionsPending += pending =>
            ui.TryEnqueue(() => { if (Content?.XamlRoot is { } root) _ = Relaya.Settings.DeletionsDialog.Show(root, pending); });
        Platform.SyncService.Shared.Changed += () => ui.TryEnqueue(UpdateSyncButton);
        UpdateSyncButton();
        Platform.ConsentGrace.WatchSessionLock();
        Platform.SyncService.Shared.ScheduleAuto();
        Platform.TunnelManager.Shared.StartAuto();
        // A login gate file that cannot be written leaves agents with the old state (B-7, V-11).
        Platform.LoginGate.WriteFailed += Notify;
        // Пока работают туннели и есть значок в трее, закрытие прячет окно (8.6, как на Mac).
        AppWindow.Closing += (_, a) => { if (HideToTray()) a.Cancel = true; };
        Closed += (_, _) => { Platform.TunnelManager.Shared.StopAll(); Platform.DavBridge.UnmountAll(); };
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
                X = work.X + Math.Max(0, (work.Width - rect.Width) / 2),
                Y = work.Y + Math.Max(0, (work.Height - rect.Height) / 2),
                Width = Math.Min(rect.Width, work.Width),
                Height = Math.Min(rect.Height, work.Height),
            });
        }
#else
        // В Uno нет DisplayArea для проверки экранов; за край экрана окно вернёт оконный менеджер X11 (Е.5).
        if (restored) AppWindow.MoveAndResize(rect);
        else AppWindow.Resize(new Windows.Graphics.SizeInt32 { Width = rect.Width, Height = rect.Height });
#endif
        AppWindow.Changed += (w, e) =>
        {
            if (!(e.DidSizeChange || e.DidPositionChange) || w.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: not Microsoft.UI.Windowing.OverlappedPresenterState.Restored })
                return;
            Platform.Settings.Set("window.bounds", $"{w.Position.X},{w.Position.Y},{w.Size.Width},{w.Size.Height}");
        };
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
            Content = new FontIcon { Glyph = "\uE71C", FontSize = Pages.Ui.IconSmall },
            Flyout = menu,
            Padding = new Thickness(4),
            Background = Pages.Ui.Brush("SubtleFillColorTransparentBrush"),
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(button, L("Фильтр по меткам"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, L("Фильтр по меткам"));
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { title, button } };
    }

    private void Render(string query)
    {
        EmptyTitle.Text = AppState.Hosts.Count == 0 ? L("Хостов пока нет — добавьте первый кнопкой «Новый хост…»") : L("Выберите хост слева");
        Nav.MenuItems.Clear();
        // With tags the header holds a filter button: NavigationViewItemHeader shows only text (Uno printed the
        // StackPanel type name, WinUI left a gap), so it is a plain item that cannot be selected.
        var header = HostsHeader();
        Nav.MenuItems.Add(header is TextBlock t
            ? new NavigationViewItemHeader { Content = t.Text }
            : new NavigationViewItem { Content = header, SelectsOnInvoked = false, IsTabStop = false });
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
                Content = group.Key,
                Icon = new FontIcon { Glyph = "" },
                SelectsOnInvoked = false,
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
                var item = new NavigationViewItem { Content = d.name, Tag = d, SelectsOnInvoked = false, Icon = new FontIcon { Glyph = d.kind == DesktopKind.Rdp ? "" : "" } };
                var menu = new MenuFlyout();
                void Add(string text, Action act) { var mi = new MenuFlyoutItem { Text = text }; mi.Click += (_, _) => act(); menu.Items.Add(mi); }
                Add(L("Подключить"), () => Platform.DesktopLauncher.Open(d, Content.XamlRoot));
                Add(L("Открыть в отдельном окне"), () => Platform.DesktopLauncher.OpenInWindow(d));
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
                Orientation = Orientation.Horizontal,
                Spacing = 8,
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
            // Пункт внутри группы WinUI присылает ItemInvoked дважды на один щелчок — второй стол не открываем.
            case RemoteDesktop d when openedDesktop is { } o && o.Id == d.id && Environment.TickCount64 - o.At < 700: break;
            case RemoteDesktop d:
                openedDesktop = (d.id, Environment.TickCount64);
                Platform.DesktopLauncher.Open(d, Content.XamlRoot);
                break;
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
    private (string Id, long At)? openedDesktop;

    /// Пустая область «Выберите хост слева» (например, отмена «Нового хоста»).
    internal void ShowNothing()
    {
        Tabs.SelectedItem = null;
        Show(null);
    }

    /// Страница слева-справа (карточка хоста, ключи…): снимает выбор вкладки.
    public void ShowPage(UIElement page)
    {
        gridMode = false;
        Tabs.SelectedItem = null;
        Show(page);
    }

    // Е.12, как на Mac: «Сетка: все терминалы сразу» — все вкладки терминалов плитками одной сеткой (Ctrl+Shift+G).
    private bool gridMode;

    internal void ToggleGrid()
    {
        gridMode = !gridMode;
        Show((Tabs.SelectedItem as TabStripItem)?.Tag is Tab t ? t.Content : null);
    }

    private bool ShowGrid()
    {
        TabHost.RowDefinitions.Clear();
        TabHost.ColumnDefinitions.Clear();
        var terminals = TabHost.Children.OfType<Terminal.TileHost>().Cast<FrameworkElement>().ToList();
        if (terminals.Count == 0) gridMode = false; // без терминалов сетки нет — и пункт меню не остаётся отмеченным
        if (!gridMode)
        {
            foreach (var c in TabHost.Children.OfType<FrameworkElement>()) { Grid.SetRow(c, 0); Grid.SetColumn(c, 0); }
            return false;
        }
        var cols = (int)Math.Ceiling(Math.Sqrt(terminals.Count));
        var rows = (terminals.Count + cols - 1) / cols;
        for (var i = 0; i < cols; i++) TabHost.ColumnDefinitions.Add(new ColumnDefinition());
        for (var i = 0; i < rows; i++) TabHost.RowDefinitions.Add(new RowDefinition());
        foreach (var c in TabHost.Children) c.Visibility = Visibility.Collapsed;
        for (var i = 0; i < terminals.Count; i++)
        {
            Grid.SetRow(terminals[i], i / cols);
            Grid.SetColumn(terminals[i], i % cols);
            terminals[i].Visibility = Visibility.Visible;
        }
        Page.Content = null;
        Page.Visibility = Visibility.Collapsed;
        Empty.Visibility = Visibility.Collapsed;
        ApplyBackground();
        return true;
    }

    private void Show(UIElement? page)
    {
        shownTab = page == null ? null : Tabs.TabItems.OfType<TabStripItem>().FirstOrDefault(i => (i.Tag as Tab)?.Content == page);
        if (ShowGrid()) return;
        // Вкладки не вынимаются из дерева (иначе Win2D теряет Canvas) — показывается одна, остальные свёрнуты.
        var tab = page != null && TabHost.Children.Contains(page);
        foreach (var c in TabHost.Children) c.Visibility = c == page ? Visibility.Visible : Visibility.Collapsed;
        Page.Content = tab ? null : page;
        Page.Visibility = tab ? Visibility.Collapsed : Visibility.Visible;
        Empty.Visibility = page is null ? Visibility.Visible : Visibility.Collapsed;
        ApplyBackground();
    }

    private string? backgroundLoaded;

    /// Картинка фона (12.2): под вкладкой — если «под терминалами», под разделом — если «под разделами».
    /// Терминал сам делает свой фон полупрозрачным (Appearance.SessionOpacity); разделам непрозрачность даёт вуаль.
    internal void ApplyBackground()
    {
        var path = Platform.Appearance.ImagePath;
        if (path != backgroundLoaded)
        {
            backgroundLoaded = path;
            BackgroundBrush.ImageSource = path == null ? null : new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(path));
        }
        var tab = Page.Visibility == Visibility.Collapsed;
        var show = path != null && (tab ? Platform.Appearance.UnderSessions : Page.Content != null && Platform.Appearance.UnderInterface);
        BackgroundImage.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        BackgroundVeil.Visibility = show && !tab ? Visibility.Visible : Visibility.Collapsed;
        BackgroundVeil.Opacity = Platform.Appearance.PanelOpacity;
    }

    // --- Вкладки: терминалы (с плитками) и SFTP. Вкладка в заголовке, содержимое — в основной области. ---

    public void OpenSession(string alias, string? initialInput = null)
    {
        var tiles = new Terminal.TileHost();
        var tab = AddTab(alias, "", tiles, tiles);
        Microsoft.UI.Xaml.Media.Brush? Tint() =>
            Pages.HostColors.Of(AppState.Host(alias)?.color) is { } c ? new Microsoft.UI.Xaml.Media.SolidColorBrush(c) : null;
        tab.SetIcon("\uE756", Tint());
        tiles.TitleChanged += t => ui.TryEnqueue(() => tab.Header = t);
        tiles.AliveChanged += alive => ui.TryEnqueue(() => tab.SetIcon(alive ? "\uE756" : "\uE783", Tint()));
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
        // Е.11 и 4.16, как на Mac: tmux у открытой вкладки (её активной плитки).
        var tmux = new ToggleMenuFlyoutItem { Text = L("Сессия tmux") };
        ToolTipService.SetToolTip(tmux, L("Вкладка переподключится: при включении — внутри tmux, при выключении сессия на сервере закроется."));
        tmux.Click += (_, _) => tiles.ActiveSession?.SetTmux(tmux.IsChecked);
        var keep = new MenuFlyoutItem { Text = L("Отсоединить и оставить на сервере") };
        ToolTipService.SetToolTip(keep, L("Сессия tmux продолжит работать; сервер закроет её через сутки без подключения."));
        keep.Click += async (_, _) =>
        {
            if (tiles.ActiveSession is not { } s) return;
            var r = await s.KeepTmuxAsync();
            if (r.Status != 0) { await Pages.Ui.ShowError(Content.XamlRoot, L("Команда не выполнена."), r.Stderr.Trim()); return; }
            tiles.CloseActive();
            if (tiles.IsEmpty) CloseTabOf(tiles);
        };
        menu.Opening += (_, _) =>
        {
            var on = tiles.ActiveSession?.UsesTmux == true;
            tmux.IsChecked = on;
            keep.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        };
        menu.Items.Add(tmux);
        menu.Items.Add(keep);
        menu.Items.Add(new MenuFlyoutSeparator());
        var grid = new ToggleMenuFlyoutItem { Text = L("Сетка: все терминалы сразу"), KeyboardAcceleratorTextOverride = "Ctrl+Shift+G" };
        grid.Click += (_, _) => ToggleGrid();
        menu.Opening += (_, _) => grid.IsChecked = gridMode;
        menu.Items.Add(grid);
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
            Title = L("Сохранить раскладку"),
            Content = name,
            PrimaryButtonText = L("Сохранить"),
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot,
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

    /// Вкладка с плитками, которую сейчас перетаскивают (полоса вкладок → холст другой вкладки).
    internal static Terminal.TileHost? DraggedTiles;

    /// Плитки вкладки переехали в другую — закрыть опустевшую вкладку.
    /// Закрыть вкладку с этим содержимым (плитки, переехавшие в другую вкладку; окно tmux, закрытое на сервере).
    internal void CloseTabOf(UIElement content)
    {
        if (Tabs.TabItems.OfType<TabStripItem>().FirstOrDefault(t => (t.Tag as Tab)?.Content == content) is { } tab) CloseTab(tab);
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

    private TabStripItem AddTab(string title, string glyph, UIElement content, IDisposable? owner)
    {
        var tab = new TabStripItem(title, glyph, new Tab(content, owner), CloseTab);
        var menu = new MenuFlyout();
        var close = new MenuFlyoutItem { Text = L("Закрыть вкладку") };
        close.Click += (_, _) => CloseTab(tab);
        menu.Items.Add(close);
        tab.ContextFlyout = menu;
        content.Visibility = Visibility.Collapsed;
        TabHost.Children.Add(content);
        Tabs.TabItems.Add(tab);
        Tabs.SelectedItem = tab;
        return tab;
    }

    private sealed record Tab(UIElement Content, IDisposable? Owner);

    /// <summary>Shows a passive notice over the content; safe to call from any thread.</summary>
    internal void Notify(string message) => ui.TryEnqueue(() =>
    {
        Notice.Message = message;
        Notice.IsOpen = true;
    });

    /// tmux-сессии всех открытых вкладок: уборка старых сессий их не трогает (К10).
    internal List<string> OpenTmuxNames => Tabs.TabItems.OfType<TabStripItem>()
        .Select(t => (t.Tag as Tab)?.Content).OfType<Terminal.TileHost>().SelectMany(t => t.TmuxNames).ToList();

    /// Терминал активной вкладки — для сниппетов и действий ОС.
    internal Terminal.TerminalView? ActiveTerminal =>
        ((Tabs.SelectedItem as TabStripItem)?.Tag as Tab)?.Content is Terminal.TileHost t ? t.Active : null;

    /// Последняя открытая терминальная вкладка (страница сниппетов закрывает выбор вкладки).
    internal Terminal.TerminalView? LastTerminal => Tabs.TabItems.OfType<TabStripItem>().Reverse()
        .Select(t => (t.Tag as Tab)?.Content).OfType<Terminal.TileHost>().Select(t => t.Active).FirstOrDefault();

    internal void SelectTerminal(Terminal.TerminalView view)
    {
        foreach (var t in Tabs.TabItems.OfType<TabStripItem>())
            if ((t.Tag as Tab)?.Content is Terminal.TileHost host && host.Contains(view)) { Tabs.SelectedItem = t; return; }
    }

    // Вкладка, выбранная до последнего переключения, — цель перетаскивания вкладки на плитки.
    private TabStripItem? previousTab;

    // Вкладка, чьи плитки на экране, пока перетаскивают другую (null — перетаскивания нет).
    // Вкладка на экране; вкладка, чьи плитки на экране во время перетаскивания другой; ожидающая показа после отпускания.
    private TabStripItem? shownTab;

    private void OnTabSelected(TabStripItem? removed, TabStripItem? added)
    {
        if (removed != null) previousTab = removed;
        if (added?.Tag is Tab t)
        {
            Nav.SelectedItem = null;
            Show(t.Content);
        }
        else if (Page.Visibility == Visibility.Collapsed)
        {
            Show(null);
        }
    }

    private void CloseTab(TabStripItem tab)
    {
        if (tab.Tag is Tab t) { t.Owner?.Dispose(); TabHost.Children.Remove(t.Content); }
        Tabs.TabItems.Remove(tab);
        if (Tabs.TabItems.Count == 0) Show(null);
        else if (gridMode) ShowGrid();
    }

    // Ctrl+T — новая вкладка к хосту из поиска, Ctrl+W — закрыть, Ctrl+Tab — следующая.
    public void CloseActiveTab()
    {
        if (Tabs.SelectedItem is TabStripItem t) CloseTab(t);
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
        var alias = ((Tabs.SelectedItem as TabStripItem)?.Tag as Tab)?.Content is Terminal.TileHost t ? t.ActiveAlias : null;
        return alias != null ? AppState.Host(alias) : null;
    }

    /// Тема окна из настройки app.theme (system | light | dark).
    internal void ApplyTheme()
    {
        Platform.Accent.Apply();
        if (Content is not FrameworkElement root) return;
        var theme = Platform.Settings.Get("app.theme", "system") switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        root.RequestedTheme = theme;
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
        Add(Windows.System.VirtualKey.G, cs, ToggleGrid);
        Add(Windows.System.VirtualKey.O, cs, () => { if (CurrentHost() is { } h) OpenSftp(h.alias); });
        Add(Windows.System.VirtualKey.R, cs, () =>
        {
            if (((Tabs.SelectedItem as TabStripItem)?.Tag as Tab)?.Content is Terminal.TileHost t) t.ReconnectActive();
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

    // Кнопка синхронизации в панели (11.9): видна при включённых профилях, во время синхронизации — кольцо,
    // при ошибке или конфликте подсказка ведёт в «Синхронизацию».
    private bool onboardingShown;

    private void UpdateSyncButton()
    {
        var sync = Platform.SyncService.Shared;
        var active = sync.Profiles.Where(p => p.enabled).ToList();
        SyncButton.Visibility = active.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var states = active.Select(p => sync.StateOf(p).State).ToList();
        var busy = states.Contains(Platform.SyncService.State.Syncing);
        SyncRing.IsActive = busy;
        SyncRing.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        SyncIcon.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        SyncButton.IsEnabled = !busy;
        var problem = states.Contains(Platform.SyncService.State.Conflict) || states.Contains(Platform.SyncService.State.Failed);
        SyncIcon.Glyph = problem ? "\uE783" : "\uE895";
        SyncText.Text = busy ? L("Синхронизация…") : problem ? L("Синхронизация: нужна проверка") : L("Синхронизировать");
        ToolTipService.SetToolTip(SyncButton, problem ? L("Ошибка или конфликт — откройте «Синхронизацию» в параметрах") : L("Синхронизировать сейчас"));
    }

    private async void OnSyncNow(object sender, RoutedEventArgs e)
    {
        var sync = Platform.SyncService.Shared;
        var problem = sync.Profiles.Where(p => p.enabled).Any(p => sync.StateOf(p).State is Platform.SyncService.State.Conflict or Platform.SyncService.State.Failed);
        if (problem)
        {
            var page = settingsPage ??= new Pages.SettingsPage();
            ShowPage(page);
            page.ShowSync();
            return;
        }
        await sync.SyncAll();
    }
    private void OnPaletteKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; Pages.CommandPalette.Show(this); }
    private void OnSnippetPaletteKey(KeyboardAccelerator s, KeyboardAcceleratorInvokedEventArgs e) { e.Handled = true; Pages.CommandPalette.Show(this, snippetsOnly: true); }

    public void FocusSearch() => Search.Focus(FocusState.Keyboard);
}
