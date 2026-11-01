using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Relaya.Data;
using uniffi.relaya_core;
using Windows.System;
using static Relaya.Strings;

namespace Relaya.Terminal;

/// Вкладка с терминалами-плитками, как на Mac: раскладка — дерево Row/Column из ядра (tiles_*, JSON), между плитками
/// разделители. Разделить (Ctrl+Shift+D — вправо, Ctrl+Shift+E — вниз) открывает тот же хост рядом; вкладку можно
/// перетащить на край плитки или всего холста; Ctrl+Alt+стрелки — соседняя плитка.
internal sealed class TileHost : UserControl, IDisposable
{
    // UI-очередь снимается в конструкторе (UI-поток). События приходят из фоновых потоков (ConPTY, туннели,
    // синхронизация), а свойство DispatcherQueue XAML-объекта из чужого потока в C# падает InvalidCastException.
    private readonly Microsoft.UI.Dispatching.DispatcherQueue ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();

    // Owner меняется, когда плитка переезжает в другую вкладку (перетаскивание): обработчики идут через него.
    private sealed record Pane(string Id, TerminalView View, SshSession Session, string Alias, Border Frame, TextBlock Title)
    {
        public TileHost Owner { get; set; } = null!;
        /// Сессия жива (StateChanged); false — показываем «отключён» в панели (4.24).
        public bool Alive { get; set; } = true;
    }

    private readonly List<Pane> panes = new();
    private readonly Grid grid = new();
    // Подсветка будущего места плитки при перетаскивании вкладки.
    private readonly Border dropHint = new()
    {
        Background = Pages.Ui.Brush("AccentFillColorDefaultBrush"), Opacity = 0.25, CornerRadius = new CornerRadius(8),
        Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
    };
    private string? layout; // TileLayout JSON ядра
    private (Edge Edge, string? Target)? drop;
    private readonly AutoSuggestBox search = new() { Width = 260, QueryIcon = new SymbolIcon(Symbol.Find), Visibility = Visibility.Collapsed };
    private Pane? active;
    private int searchFrom = int.MaxValue;
    // Рассылка ввода (как на Mac): переключатель в панели и предупреждение, пока она включена.
    private readonly Microsoft.UI.Xaml.Controls.Primitives.ToggleButton broadcastToggle = new()
    {
        Content = new FontIcon { Glyph = "\uEC05", FontSize = 16 }, Padding = new Thickness(8),
    };
    private readonly InfoBar broadcastBar = new() { Severity = InfoBarSeverity.Warning, IsClosable = false, Margin = new Thickness(8, 0, 8, 4) };
    private readonly CheckBox broadcastHere = new();
    // Запись сессии активной плитки в файл (4.14): переключатель и «Показать файл записи».
    private readonly Microsoft.UI.Xaml.Controls.Primitives.ToggleButton recordToggle = new()
    {
        Content = new FontIcon { Glyph = "\uE7C8", FontSize = 16 }, Padding = new Thickness(8),
    };
    // Порты сервера из вывода активной плитки: «:3000» — открыть в браузере через туннель.
    private readonly StackPanel portsPanel = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
    // Состояние активной плитки рядом с портами, как строка состояния на Mac (4.24).
    private readonly TextBlock disconnected = new()
    {
        VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 4, 0), Visibility = Visibility.Collapsed,
    };

    public event Action<string>? TitleChanged;
    public event Action<bool>? AliveChanged;

    public TerminalView? Active => active?.View;
    public string? ActiveAlias => active?.Alias;
    public SshSession? ActiveSession => active?.Session;
    public bool IsEmpty => panes.Count == 0;

    /// Закрыть активную плитку (сессию не завершать — tmux на сервере остаётся).
    public void CloseActive()
    {
        if (active is { } p) Close(p);
    }

    /// Переподключить активную плитку (Ctrl+Shift+R).
    public void ReconnectActive()
    {
        if (active is { } p) { p.Session.Start(); p.View.Focus(FocusState.Programmatic); }
    }
    public IEnumerable<string> TmuxNames => panes.Select(p => p.Session.TmuxName);
    public bool Contains(TerminalView v) => panes.Any(p => p.View == v);

    public TileHost()
    {
        search.PlaceholderText = L("Найти в выводе (Enter — дальше)");
        search.QuerySubmitted += (_, _) => FindNext();
        search.TextChanged += (_, args) => { if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) { searchFrom = int.MaxValue; FindNext(); } };
        search.KeyDown += (_, e) => { if (e.Key == VirtualKey.Escape) CloseSearch(); };
        var broadcastTip = L("Ввод во все терминалы");
        ToolTipService.SetToolTip(broadcastToggle, broadcastTip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(broadcastToggle, broadcastTip);
        broadcastToggle.Click += (_, _) => Broadcast.Enabled = broadcastToggle.IsChecked == true;
        var stopBroadcast = new Button { Content = L("Выключить") };
        stopBroadcast.Click += (_, _) => Broadcast.Enabled = false;
        broadcastBar.ActionButton = stopBroadcast;
        broadcastHere.Content = L("Этот терминал участвует");
        broadcastHere.Click += (_, _) => { if (active != null) Broadcast.SetIncluded(active.Session, broadcastHere.IsChecked == true); };
        broadcastBar.Content = broadcastHere;
        Broadcast.Changed += OnBroadcastChanged;
        var recordTip = L("Записывать сессию в файл (Ctrl+Shift+L)");
        ToolTipService.SetToolTip(recordToggle, recordTip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(recordToggle, recordTip);
        recordToggle.Click += (_, _) => active?.Session.ToggleRecording();
        var showRecording = new MenuFlyout();
        var showItem = new MenuFlyoutItem { Text = L("Показать файл записи") };
        showItem.Click += (_, _) => Platform.Shell.OpenFolder(SshSession.RecordingsFolder);
        showRecording.Items.Add(showItem);
        recordToggle.ContextFlyout = showRecording;
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 4, 8, 4),
            Children =
            {
                connectionInfo,
                disconnected,
                portsPanel,
                search,
                recordToggle,
                broadcastToggle,
                // Кнопки разделения — тот же путь, что Ctrl+Shift+D/E: на Skia X11 нет перетаскивания вкладок (Л4).
                Pages.Ui.IconButton("\uE90D", L("Разделить вправо (Ctrl+Shift+D)"), () => Split(Edge.Right)),
                Pages.Ui.IconButton("\uE90E", L("Разделить вниз (Ctrl+Shift+E)"), () => Split(Edge.Bottom)),
                Pages.Ui.IconButton("", L("Поиск (Ctrl+Shift+F)"), OpenSearch),
                Pages.Ui.IconButton("", L("Мельче (Ctrl+−)"), () => active?.View.ZoomFont(-1)),
                Pages.Ui.IconButton("", L("Крупнее (Ctrl+=)"), () => active?.View.ZoomFont(1)),
            },
        };
        // Е.20, как на Mac: действия хоста активной плитки над терминалом. Команды вставляются без Enter.
        var osMenu = new MenuFlyout();
        var osButton = new DropDownButton { Content = L("Действия"), Flyout = osMenu };
        osMenu.Opening += (_, _) =>
        {
            osMenu.Items.Clear();
            var h = ActiveAlias is { } a ? AppState.Host(a) : null;
            var actions = h?.os is { } os ? RelayaCoreMethods.OsActions(os) : null;
            if (h == null || actions is not { Count: > 0 })
            {
                osMenu.Items.Add(new MenuFlyoutItem { Text = L("Система не определена — откройте карточку хоста"), IsEnabled = false });
                return;
            }
            foreach (var act in actions)
            {
                var item = new MenuFlyoutItem { Text = L(act.title) };
                item.Click += (_, _) => active?.View.Paste(RelayaCoreMethods.OsCommandForUser(act.command, h.user ?? ""));
                osMenu.Items.Add(item);
            }
        };
        var snippetMenu = new MenuFlyout();
        var snippetButton = new DropDownButton { Content = L("Сниппеты"), Flyout = snippetMenu };
        ToolTipService.SetToolTip(snippetButton, L("Вставить сохранённую команду"));
        snippetMenu.Opening += (_, _) =>
        {
            snippetMenu.Items.Clear();
            var list = AppState.Snippets.OrderBy(sn => sn.name).ToList();
            if (list.Count == 0) snippetMenu.Items.Add(new MenuFlyoutItem { Text = L("Сниппетов нет"), IsEnabled = false });
            foreach (var sn in list)
            {
                var item = new MenuFlyoutItem { Text = sn.name };
                ToolTipService.SetToolTip(item, sn.command);
                item.Click += (_, _) => { if (MainWindow.Current is { } w) Pages.CommandPalette.InsertSnippet(w, sn, active?.View); };
                snippetMenu.Items.Add(item);
            }
        };
        var files = new Button { Content = "SFTP" };
        ToolTipService.SetToolTip(files, L("Файлы на сервере"));
        files.Click += (_, _) => { if (ActiveAlias is { } a) MainWindow.Current?.OpenSftp(a); };
        var edit = new Button { Content = L("Изменить хост") };
        edit.Click += (_, _) => { if (ActiveAlias is { } a && AppState.Host(a) is { } h) _ = Pages.HostEditor.Show(XamlRoot, h, false); };
        var keyLogin = new Button { Content = L("Вход по ключу…") };
        keyLogin.Click += (_, _) => { if (ActiveAlias is { } a && AppState.Host(a) is { } h) MainWindow.Current?.ShowPage(new Pages.KeyWizardPage(h)); };
        var hostBar = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(8, 4, 0, 4),
            Children = { osButton, snippetButton, files, edit, keyLogin },
        };
        // Прозрачный фон: без него пустые места холста не получают DragOver/Drop.
        var stage = new Grid { Background = Pages.Ui.Brush("SubtleFillColorTransparentBrush"), Children = { grid, dropHint } };
        // Панели хоста и плиток — в колонках одной строки: при узком окне не наезжают друг на друга.
        var toolbar = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto } } };
        toolbar.Children.Add(hostBar);
        Grid.SetColumn(bar, 1);
        toolbar.Children.Add(bar);
        var root = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() { Height = GridLength.Auto }, new() } };
        root.Children.Add(toolbar);
        Grid.SetRow(broadcastBar, 1);
        root.Children.Add(broadcastBar);
        Grid.SetRow(stage, 2);
        root.Children.Add(stage);
        Content = root;
        // Вкладку перетаскивают на этот холст (MainWindow.DraggedTiles): край плитки или всего холста.
        AllowDrop = true;
        DragOver += (_, e) =>
        {
            if (MainWindow.DraggedTiles is not { } src || src == this || panes.Count == 0) { e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.None; HideHint(); return; }
            e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move;
            e.DragUIOverride.IsCaptionVisible = false;
            drop = Zone(e.GetPosition(grid));
            ShowHint(drop.Value);
        };
        DragLeave += (_, _) => HideHint();
        Drop += (_, e) =>
        {
            HideHint();
            if (MainWindow.DraggedTiles is { } src && src != this && drop is { } d) Adopt(src, d.Edge, d.Target);
        };
        KeyboardAccelerators.Add(Accel(VirtualKey.F, () => OpenSearch()));
        KeyboardAccelerators.Add(Accel(VirtualKey.L, () => active?.Session.ToggleRecording()));
        KeyboardAccelerators.Add(Accel(VirtualKey.D, () => Split(Edge.Right)));
        KeyboardAccelerators.Add(Accel(VirtualKey.E, () => Split(Edge.Bottom)));
        KeyboardAccelerators.Add(Accel(VirtualKey.Enter, ToggleZoom));
        foreach (var (key, edge) in new[] { (VirtualKey.Left, Edge.Left), (VirtualKey.Right, Edge.Right), (VirtualKey.Up, Edge.Top), (VirtualKey.Down, Edge.Bottom) })
        {
            var a = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu };
            a.Invoked += (_, e) => { e.Handled = true; FocusNeighbor(edge); };
            KeyboardAccelerators.Add(a);
        }
        KeyboardAccelerators.Add(Accel(VirtualKey.W, () => { if (active != null && panes.Count > 1) Close(active); }));
    }

    private static KeyboardAccelerator Accel(VirtualKey key, Action action)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift };
        a.Invoked += (_, e) => { e.Handled = true; action(); };
        return a;
    }

    /// Фокус ввода — в активный терминал; ещё не загружен — как только загрузится.
    public void FocusActive()
    {
        if (active?.View is not { } view) return;
        if (view.IsLoaded) { view.Focus(FocusState.Programmatic); return; }
        void Once(object sender, RoutedEventArgs e) { view.Loaded -= Once; view.Focus(FocusState.Programmatic); }
        view.Loaded += Once;
    }

    /// Та же сессия (тот же хост) рядом с активной плиткой.
    public void Split(Edge edge)
    {
        zoomed = null; // новая плитка видна рядом
        if (active is { } a) Add(a.Alias, null, edge, a.Id);
    }

    /// Раскладка для сохранения: листья — алиасы хостов (формат layouts.json).
    public string? SaveableLayout()
    {
        if (layout == null) return null;
        return Data.SavedLayouts.MapLeaves(System.Text.Json.Nodes.JsonNode.Parse(layout), id => panes.FirstOrDefault(p => p.Id == id)?.Alias)?.ToJsonString();
    }

    /// Открыть сохранённую раскладку: по сессии на каждый лист-хост; хостов, которых больше нет, пропускаем.
    public bool Open(string saved)
    {
        var ids = new List<string>();
        var tree = Data.SavedLayouts.MapLeaves(System.Text.Json.Nodes.JsonNode.Parse(saved), alias =>
        {
            if (AppState.Host(alias) == null) return null;
            var id = AddPane(alias, null);
            ids.Add(id);
            return id;
        });
        if (tree == null || ids.Count == 0) return false;
        layout = RelayaCoreMethods.TilesSynced(tree.ToJsonString(), ids) ?? tree.ToJsonString();
        Layout();
        Activate(panes[0]);
        return true;
    }

    public void Add(string alias, string? initialInput = null, Edge? edge = null, string? target = null)
    {
        var id = AddPane(alias, initialInput);
        layout = layout == null ? RelayaCoreMethods.TilesAutomatic(new List<string> { id })
            : edge is { } e ? RelayaCoreMethods.TilesInserting(layout, id, e, target) : RelayaCoreMethods.TilesAppending(layout, id);
        Layout();
        Activate(panes[^1]);
    }

    // Плитка с сессией, без изменения раскладки.
    private string AddPane(string alias, string? initialInput)
    {
        var id = Guid.NewGuid().ToString("N");
        var view = new TerminalView();
        var session = new SshSession(view, alias);
        var title = new TextBlock { Text = alias, Style = Pages.Ui.Style("CaptionTextBlockStyle"), Margin = new Thickness(8, 2, 8, 2) };
        var close = Pages.Ui.IconButton("", L("Закрыть плитку (Ctrl+Shift+W)"), () => { });
        var expand = Pages.Ui.IconButton("\uE740", L("Развернуть плитку (Ctrl+Shift+Enter)"), () => { });
        var header = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto }, new() { Width = GridLength.Auto } }, Children = { title } };
        Grid.SetColumn(expand, 1);
        header.Children.Add(expand);
        Grid.SetColumn(close, 2);
        header.Children.Add(close);
        // Запрос пароля после входа: InfoBar над терминалом, ввод не блокируется.
        var ask = new InfoBar
        {
            Title = L("Запрос пароля"), Message = L("Подставить пароль хоста?"), Severity = InfoBarSeverity.Informational,
            IsClosable = false, Margin = new Thickness(4, 0, 4, 4),
        };
        var put = new Button { Content = L("Подставить"), Style = Pages.Ui.Style("AccentButtonStyle") };
        var no = new Button { Content = L("Нет") };
        ask.Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 8), Children = { put, no } };
        put.Click += (_, _) => { ask.IsOpen = false; session.SendPassword(); view.Focus(FocusState.Programmatic); };
        no.Click += (_, _) => { ask.IsOpen = false; view.Focus(FocusState.Programmatic); };
        session.PasswordRequested += () => ui.TryEnqueue(() => ask.IsOpen = true);
        // 4.20, как на Mac: сервер спрашивает пароль, а сохранённого нет — «Ввести и сохранить…»;
        // сохранённый не подошёл — «Ввести новый…». Пароль вводится в запрос ssh и сохраняется по флажку.
        var login = new InfoBar { Severity = InfoBarSeverity.Informational, IsClosable = true, Margin = new Thickness(4, 0, 4, 4) };
        var enter = new Button { Style = Pages.Ui.Style("AccentButtonStyle") };
        var saveByDefault = true; // сохранённый пароль, не подставленный из-за ProxyCommand, не перезаписываем по умолчанию
        login.ActionButton = enter;
        enter.Click += async (_, _) =>
        {
            login.IsOpen = false;
            var box = new PasswordBox { Header = L("Пароль") };
            var save = new CheckBox { Content = Platform.PlatformText.PasswordSaved(), IsChecked = saveByDefault };
            var d = new ContentDialog
            {
                Title = L("Пароль для %@", alias), Content = new StackPanel { Spacing = 8, Children = { box, save } },
                PrimaryButtonText = L("Ввести"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
            };
            if (await d.ShowAsync() == ContentDialogResult.Primary && box.Password.Length > 0)
            {
                try { session.TypeLoginPassword(box.Password, save.IsChecked == true); }
                catch (Exception e) { await Pages.Ui.ShowError(XamlRoot, L("Не удалось сохранить пароль"), e.Message); }
            }
            view.Focus(FocusState.Programmatic);
        };
        session.LoginPasswordNeeded += none => ui.TryEnqueue(() =>
        {
            var held = none && Platform.CredentialStore.Has(alias) && !Platform.Askpass.CanAutofill(alias);
            saveByDefault = !held;
            login.Title = held ? L("Сохранённый пароль не подставляется (ProxyCommand)") : none ? L("Сервер спрашивает пароль") : L("Сохранённый пароль не подошёл");
            enter.Content = held ? L("Ввести…") : none ? L("Ввести и сохранить…") : L("Ввести новый…");
            login.IsOpen = true;
        });
        // Вошли по паролю — предложить ключ: «Настроить», «Не сейчас», «Больше не предлагать».
        var offer = new InfoBar
        {
            Title = L("Настроить вход по ключу?"), Message = L("Без пароля и надёжнее: Relaya создаст ключ, добавит его на сервер и проверит вход."),
            Severity = InfoBarSeverity.Informational, IsClosable = false, Margin = new Thickness(4, 0, 4, 4),
        };
        var setup = new Button { Content = L("Настроить"), Style = Pages.Ui.Style("AccentButtonStyle") };
        var later = new Button { Content = L("Не сейчас") };
        var never = new Button { Content = L("Больше не предлагать") };
        offer.Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 8), Children = { setup, later, never } };
        setup.Click += (_, _) =>
        {
            offer.IsOpen = false;
            if (AppState.Host(alias) is { } h) MainWindow.Current?.ShowPage(new Pages.KeyWizardPage(h));
        };
        later.Click += (_, _) => { offer.IsOpen = false; view.Focus(FocusState.Programmatic); };
        never.Click += (_, _) => { Platform.Settings.Set("terminal.offerKeySetup", "0"); offer.IsOpen = false; view.Focus(FocusState.Programmatic); };
        session.KeySetupOffered += () => ui.TryEnqueue(() => { login.IsOpen = false; offer.IsOpen = true; });
        // Ключ сервера при первом подключении (как окно на Mac): ContentDialog с отпечатком, по умолчанию «Отмена».
        // 4.19, как на Mac: ключ сервера изменился — ssh отказал; ничего не удаляем за пользователя.
        var keyChanged = new InfoBar
        {
            Severity = InfoBarSeverity.Error, IsClosable = true, Margin = new Thickness(4, 0, 4, 4),
            Message = L("Ключ сервера изменился! Это может быть атака «человек посередине». ssh не подключится, пока вы не проверите сервер и не удалите старую запись из ~/.ssh/known_hosts."),
        };
        session.HostKeyChanged += () => ui.TryEnqueue(() => keyChanged.IsOpen = true);
        // 4.22: после «Too many authentication failures» переподключились по паролю — сказать почему.
        var passwordOnlyBar = new InfoBar
        {
            Severity = InfoBarSeverity.Informational, IsClosable = true, Margin = new Thickness(4, 0, 4, 4),
            Message = L("Сервер оборвал вход после перебора ключей из ssh-agent — переподключились сразу по паролю. Настройте вход по ключу, чтобы так не было."),
        };
        session.PasswordOnlySwitched += () => ui.TryEnqueue(() => passwordOnlyBar.IsOpen = true);
        // 4.15: отсчёт до переподключения после обрыва — «Переподключить» сейчас или «Отменить».
        var reconnectBar = new InfoBar { Severity = InfoBarSeverity.Warning, IsClosable = false, Margin = new Thickness(4, 0, 4, 4) };
        var now = new Button { Content = L("Переподключить"), Style = Pages.Ui.Style("AccentButtonStyle") };
        var stop = new Button { Content = L("Отменить") };
        now.Click += (_, _) => { session.Start(); view.Focus(FocusState.Programmatic); };
        stop.Click += (_, _) => session.CancelReconnect();
        reconnectBar.Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 8), Children = { now, stop } };
        session.ReconnectCountdown += left =>
        {
            reconnectBar.IsOpen = left != null;
            if (left is { } n) reconnectBar.Title = L("Переподключение через %@ с…", n.ToString());
        };
        session.HostKeyRequested += fp => ui.TryEnqueue(async () =>
        {
            if (XamlRoot == null) { session.AnswerHostKey(false); return; }
            var dialog = new ContentDialog
            {
                Title = L("Первое подключение к %@", alias),
                Content = new StackPanel
                {
                    Spacing = 8,
                    Children =
                    {
                        Pages.Ui.Secondary(L("Сверьте отпечаток ключа сервера с тем, что показывает сам сервер (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub).")),
                        new TextBlock { Text = fp, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap,
                            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas") },
                    },
                },
                PrimaryButtonText = L("Подключиться"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot,
            };
            bool trust;
            try { trust = await dialog.ShowAsync() == ContentDialogResult.Primary; }
            catch (Exception) { trust = false; } // уже открыт другой диалог — безопасный ответ
            session.AnswerHostKey(trust);
            view.Focus(FocusState.Programmatic);
        });
        // Начальная команда (сниппет, tmux attach) не дождалась входа — не вводим сами, предлагаем вставить.
        var pending = new InfoBar
        {
            Title = L("Команда не вставлена"), Message = L("Сессия не дошла до приглашения shell."), Severity = InfoBarSeverity.Informational,
            IsClosable = true, Margin = new Thickness(4, 0, 4, 4),
        };
        var paste = new Button { Content = L("Вставить") };
        pending.ActionButton = paste;
        paste.Click += (_, _) =>
        {
            pending.IsOpen = false;
            if (pending.Tag is string text) { if (text.EndsWith('\r')) view.Type(text); else view.Paste(text); }
            view.Focus(FocusState.Programmatic);
        };
        var body = new Grid();
        body.Children.Add(header);
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        // Баннеры — каждый в своей строке, чтобы не накладывались; терминал — в последней.
        foreach (var bar in new FrameworkElement[] { keyChanged, passwordOnlyBar, reconnectBar, ask, offer, login, pending })
        {
            body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(bar, body.RowDefinitions.Count - 1);
            body.Children.Add(bar);
        }
        body.RowDefinitions.Add(new RowDefinition());
        Grid.SetRow(view, body.RowDefinitions.Count - 1);
        body.Children.Add(view);
        var frame = new Border { Child = body, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4), Margin = new Thickness(4) };
        var pane = new Pane(id, view, session, alias, frame, title) { Owner = this };
        close.Click += (_, _) => pane.Owner.Close(pane);
        expand.Click += (_, _) => { pane.Owner.Activate(pane); pane.Owner.ToggleZoom(); };
        view.GotFocus += (_, _) => pane.Owner.Activate(pane);
        session.StateChanged += alive =>
        {
            pane.Owner.AliveChanged?.Invoke(alive);
            pane.Owner.ui.TryEnqueue(() =>
            {
                pane.Alive = alive;
                if (pane.Owner.active == pane) pane.Owner.UpdateState();
            });
        };
        session.RecordingChanged += () => pane.Owner.ui.TryEnqueue(() => { if (pane.Owner.active == pane) pane.Owner.UpdateRecording(); });
        session.PortsChanged += () => pane.Owner.ui.TryEnqueue(() => { if (pane.Owner.active == pane) pane.Owner.UpdatePorts(); });
        var started = false;
        view.Loaded += (_, _) =>
        {
            if (started) return;
            started = true;
            session.Start();
            if (initialInput != null) _ = TypeWhenReadyAsync(view, initialInput, pending);
            view.Focus(FocusState.Programmatic);
        };
        panes.Add(pane);
        return id;
    }

    // Плитки другой вкладки переезжают сюда (перетаскивание вкладки): первая — к краю цели, остальные — рядом с ней.
    private void Adopt(TileHost source, Edge edge, string? target)
    {
        var moving = source.panes.ToList();
        source.panes.Clear();
        source.layout = null;
        source.grid.Children.Clear();
        foreach (var p in moving)
        {
            p.Owner = this;
            panes.Add(p);
            layout = RelayaCoreMethods.TilesInserting(layout!, p.Id, edge, target);
            target = p.Id;
        }
        Layout();
        if (moving.Count > 0) { Activate(moving[0]); moving[0].View.Focus(FocusState.Programmatic); }
        MainWindow.Current?.CloseTabOf(source);
    }

    private void FocusNeighbor(Edge edge)
    {
        if (active == null || layout == null) return;
        if (RelayaCoreMethods.TilesNeighbor(layout, active.Id, edge) is { } id && panes.FirstOrDefault(p => p.Id == id) is { } p)
            p.View.Focus(FocusState.Programmatic);
    }

    // Команда для новой сессии (сниппет, логи Docker, tmux attach) — когда ядро говорит, что вход выполнен (C23).
    // Не дождались за 10 с — команду не вводим, а показываем InfoBar «Вставить».
    private static async System.Threading.Tasks.Task TypeWhenReadyAsync(TerminalView view, string text, InfoBar pending)
    {
        for (var i = 0; i < 40; i++)
        {
            await System.Threading.Tasks.Task.Delay(250);
            if (view.Emulator.LoginReady())
            {
                if (text.EndsWith('\r')) view.Type(text); else view.Paste(text);
                return;
            }
        }
        pending.Tag = text;
        pending.IsOpen = true;
    }

    // Состояние рассылки меняется из любой вкладки — обновляем панель через UI-очередь.
    private void OnBroadcastChanged() => ui.TryEnqueue(UpdateBroadcast);

    private void UpdateBroadcast()
    {
        var on = Broadcast.Enabled;
        broadcastToggle.IsChecked = on;
        broadcastBar.IsOpen = on;
        if (!on) return;
        broadcastBar.Title = L("Ввод во все терминалы");
        broadcastBar.Message = L("Ввод рассылается в терминалы: %@. Пароли и сниппеты не рассылаются.", Broadcast.Receivers);
        broadcastHere.IsChecked = active == null || Broadcast.Includes(active.Session);
    }

    // Куда и как подключена активная плитка — как строка состояния на Mac (4.24): user@host:port и способ входа.
    private readonly TextBlock connectionInfo = new()
    {
        VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 8, 0), Opacity = 0.7,
        FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas, monospace"), FontSize = 12,
    };

    private void UpdateState()
    {
        if (active != null && Data.AppState.Host(active.Alias) is { } h)
            connectionInfo.Text = RelayaCoreMethods.HostSubtitle(h) + " · " + (h.identityFile != null ? L("ключ")
                : Platform.CredentialStore.Has(h.alias) ? L("пароль · сохранён") : L("ключ из агента или пароль"));
        else
            connectionInfo.Text = "";
        disconnected.Text = L("отключён");
        disconnected.Foreground = Pages.Ui.Brush("SystemFillColorCriticalBrush");
        disconnected.Visibility = active is { Alive: false } ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdatePorts()
    {
        portsPanel.Children.Clear();
        if (active is not { } pane) return;
        foreach (var port in pane.Session.Ports)
        {
            var b = new Button { Content = ":" + port, Padding = new Thickness(8, 4, 8, 4) };
            var tip = L("Открыть localhost:%@ сервера в браузере через туннель", port);
            ToolTipService.SetToolTip(b, tip);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
            b.Click += async (_, _) =>
            {
                try { await Platform.PortTunnel.OpenAsync(pane.Alias, port, XamlRoot); }
                catch (Exception e) { TerminalView.Trace("port tunnel: " + e.Message); }
            };
            portsPanel.Children.Add(b);
        }
    }

    private void UpdateRecording()
    {
        var path = active?.Session.RecordingPath;
        recordToggle.IsChecked = path != null;
        var tip = path != null ? L("Сессия записывается в файл: %@", path) : L("Записывать сессию в файл (Ctrl+Shift+L)");
        ToolTipService.SetToolTip(recordToggle, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(recordToggle, tip);
    }

    private void Activate(Pane pane)
    {
        active = pane;
        UpdateBroadcast();
        UpdateRecording();
        UpdatePorts();
        UpdateState();
        foreach (var p in panes)
            p.Frame.BorderBrush = p == pane && panes.Count > 1 ? Pages.Ui.Brush("AccentFillColorDefaultBrush") : Pages.Ui.Brush("CardStrokeColorDefaultBrush");
        TitleChanged?.Invoke(panes.Count > 1 ? string.Join(" · ", panes.Select(p => p.Alias)) : pane.Alias);
    }

    private void Close(Pane pane)
    {
        pane.Session.Dispose();
        pane.View.Dispose();
        panes.Remove(pane);
        layout = layout == null ? null : RelayaCoreMethods.TilesRemoving(layout, pane.Id);
        Layout();
        if (panes.Count > 0) { Activate(panes[^1]); panes[^1].View.Focus(FocusState.Programmatic); }
    }

    // Раскладка — по дереву ядра: Row — колонки, Column — строки, между ними разделители; заголовки плиток видны,
    // только когда плиток больше одной.
    // 4.3: развёрнутая плитка занимает всю вкладку; остальные живут и возвращаются тем же сочетанием.
    private Pane? zoomed;

    public void ToggleZoom()
    {
        zoomed = zoomed == null && panes.Count > 1 ? active : null;
        Layout();
        active?.View.Focus(FocusState.Programmatic);
    }

    private void Layout()
    {
        foreach (var p in panes) (p.Frame.Parent as Panel)?.Children.Remove(p.Frame);
        grid.Children.Clear();
        if (panes.Count == 0 || layout == null) return;
        layout = RelayaCoreMethods.TilesSynced(layout, panes.Select(p => p.Id).ToList()) ?? layout;
        if (zoomed != null && !panes.Contains(zoomed)) zoomed = null;
        if (zoomed != null)
        {
            ((Grid)((Grid)zoomed.Frame.Child).Children[0]).Visibility = Visibility.Visible; // заголовок — чтобы свернуть мышью
            zoomed.Frame.BorderThickness = new Thickness(0);
            zoomed.Frame.Margin = new Thickness(0);
            grid.Children.Add(zoomed.Frame);
            return;
        }
        var many = panes.Count > 1;
        foreach (var p in panes)
        {
            ((Grid)((Grid)p.Frame.Child).Children[0]).Visibility = many ? Visibility.Visible : Visibility.Collapsed;
            p.Frame.BorderThickness = new Thickness(many ? 1 : 0);
            p.Frame.Margin = new Thickness(many ? 4 : 0);
        }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(layout);
            grid.Children.Add(Build(doc.RootElement));
        }
        catch (Exception e) { TerminalView.Trace("tiles: " + e.Message); }
    }

    private UIElement Build(System.Text.Json.JsonElement node)
    {
        var prop = node.EnumerateObject().First();
        if (prop.Name == "leaf")
            return panes.First(p => p.Id == prop.Value.GetString()).Frame;
        var row = prop.Name == "row";
        var g = new Grid();
        var children = prop.Value.EnumerateArray().ToList();
        for (var i = 0; i < children.Count; i++)
        {
            if (i > 0)
            {
                // Разделитель: тянется мышью, меняет доли соседних колонок/строк.
                if (row) g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                else g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var splitter = new TileSplitter(g, row, g.Children.Count == 0 ? 0 : (row ? g.ColumnDefinitions.Count : g.RowDefinitions.Count) - 1);
                if (row) Grid.SetColumn(splitter, g.ColumnDefinitions.Count - 1); else Grid.SetRow(splitter, g.RowDefinitions.Count - 1);
                g.Children.Add(splitter);
            }
            if (row) g.ColumnDefinitions.Add(new ColumnDefinition()); else g.RowDefinitions.Add(new RowDefinition());
            var child = Build(children[i]);
            if (row) Grid.SetColumn((FrameworkElement)child, g.ColumnDefinitions.Count - 1); else Grid.SetRow((FrameworkElement)child, g.RowDefinitions.Count - 1);
            g.Children.Add(child);
        }
        return g;
    }

    // Куда ляжет перетаскиваемая вкладка: у края холста — на всю ширину/высоту, иначе — ближайший край плитки по третям.
    private (Edge Edge, string? Target) Zone(Windows.Foundation.Point at)
    {
        double w = grid.ActualWidth, h = grid.ActualHeight, band = 24;
        if (at.X < band) return (Edge.Left, null);
        if (at.X > w - band) return (Edge.Right, null);
        if (at.Y < band) return (Edge.Top, null);
        if (at.Y > h - band) return (Edge.Bottom, null);
        foreach (var p in panes)
        {
            var r = Bounds(p.Frame);
            if (!r.Contains(at)) continue;
            var dx = (at.X - r.X) / r.Width; var dy = (at.Y - r.Y) / r.Height;
            var edges = new[] { (dx, Edge.Left), (1 - dx, Edge.Right), (dy, Edge.Top), (1 - dy, Edge.Bottom) };
            return (edges.MinBy(t => t.Item1).Item2, p.Id);
        }
        return (Edge.Right, null);
    }

    private Windows.Foundation.Rect Bounds(FrameworkElement e)
    {
        var origin = e.TransformToVisual(grid).TransformPoint(new Windows.Foundation.Point(0, 0));
        return new Windows.Foundation.Rect(origin.X, origin.Y, e.ActualWidth, e.ActualHeight);
    }

    private void ShowHint((Edge Edge, string? Target) zone)
    {
        var r = zone.Target is { } id && panes.FirstOrDefault(p => p.Id == id) is { } p
            ? Bounds(p.Frame) : new Windows.Foundation.Rect(0, 0, grid.ActualWidth, grid.ActualHeight);
        var (x, y, w, h) = zone.Edge switch
        {
            Edge.Left => (r.X, r.Y, r.Width / 2, r.Height),
            Edge.Right => (r.X + r.Width / 2, r.Y, r.Width / 2, r.Height),
            Edge.Top => (r.X, r.Y, r.Width, r.Height / 2),
            _ => (r.X, r.Y + r.Height / 2, r.Width, r.Height / 2),
        };
        dropHint.Margin = new Thickness(x, y, 0, 0);
        dropHint.Width = Math.Max(0, w);
        dropHint.Height = Math.Max(0, h);
        dropHint.Visibility = Visibility.Visible;
    }

    private void HideHint() { dropHint.Visibility = Visibility.Collapsed; drop = null; }

    private void OpenSearch()
    {
        search.Visibility = Visibility.Visible;
        search.Focus(FocusState.Keyboard);
    }

    private void CloseSearch()
    {
        search.Text = "";
        search.Visibility = Visibility.Collapsed;
        active?.View.ResetView();
        active?.View.Focus(FocusState.Programmatic);
        searchFrom = int.MaxValue;
    }

    private void FindNext()
    {
        if (active == null) return;
        var found = active.View.Find(search.Text, searchFrom);
        searchFrom = found >= 0 ? found : int.MaxValue;
    }

    public void Dispose()
    {
        Broadcast.Changed -= OnBroadcastChanged;
        foreach (var p in panes) { p.Session.Dispose(); p.View.Dispose(); }
        panes.Clear();
    }
}
