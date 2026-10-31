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

    public event Action<string>? TitleChanged;
    public event Action<bool>? AliveChanged;

    public TerminalView? Active => active?.View;
    public bool Contains(TerminalView v) => panes.Any(p => p.View == v);

    public TileHost()
    {
        search.PlaceholderText = L("Найти в выводе (Enter — дальше)");
        search.QuerySubmitted += (_, _) => FindNext();
        search.TextChanged += (_, args) => { if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) { searchFrom = int.MaxValue; FindNext(); } };
        search.KeyDown += (_, e) => { if (e.Key == VirtualKey.Escape) CloseSearch(); };
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 4, 8, 4),
            Children =
            {
                search,
                Pages.Ui.IconButton("", L("Поиск (Ctrl+Shift+F)"), OpenSearch),
                Pages.Ui.IconButton("", L("Мельче (Ctrl+−)"), () => active?.View.ZoomFont(-1)),
                Pages.Ui.IconButton("", L("Крупнее (Ctrl+=)"), () => active?.View.ZoomFont(1)),
            },
        };
        var stage = new Grid { Children = { grid, dropHint } };
        var root = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() } };
        root.Children.Add(bar);
        Grid.SetRow(stage, 1);
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
        KeyboardAccelerators.Add(Accel(VirtualKey.D, () => Split(Edge.Right)));
        KeyboardAccelerators.Add(Accel(VirtualKey.E, () => Split(Edge.Bottom)));
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

    /// Та же сессия (тот же хост) рядом с активной плиткой.
    public void Split(Edge edge)
    {
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
        var header = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto } }, Children = { title } };
        Grid.SetColumn(close, 1);
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
        var body = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() { Height = GridLength.Auto }, new() { Height = GridLength.Auto }, new() } };
        body.Children.Add(header);
        Grid.SetRow(ask, 1);
        body.Children.Add(ask);
        Grid.SetRow(pending, 2);
        body.Children.Add(pending);
        Grid.SetRow(view, 3);
        body.Children.Add(view);
        var frame = new Border { Child = body, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4), Margin = new Thickness(4) };
        var pane = new Pane(id, view, session, alias, frame, title) { Owner = this };
        close.Click += (_, _) => pane.Owner.Close(pane);
        view.GotFocus += (_, _) => pane.Owner.Activate(pane);
        session.StateChanged += alive => pane.Owner.AliveChanged?.Invoke(alive);
        var started = false;
        view.Loaded += (_, _) =>
        {
            if (started) return;
            started = true;
            session.Start();
            if (initialInput != null) TypeWhenReady(view, initialInput, pending);
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
    private static async void TypeWhenReady(TerminalView view, string text, InfoBar pending)
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

    private void Activate(Pane pane)
    {
        active = pane;
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
    private void Layout()
    {
        foreach (var p in panes) (p.Frame.Parent as Panel)?.Children.Remove(p.Frame);
        grid.Children.Clear();
        if (panes.Count == 0 || layout == null) return;
        layout = RelayaCoreMethods.TilesSynced(layout, panes.Select(p => p.Id).ToList()) ?? layout;
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
        foreach (var p in panes) { p.Session.Dispose(); p.View.Dispose(); }
        panes.Clear();
    }
}
