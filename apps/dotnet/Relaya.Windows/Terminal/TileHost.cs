using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Relaya.Data;
using Windows.System;
using static Relaya.Strings;

namespace Relaya.Terminal;

/// Вкладка с терминалами-плитками, как на Mac: несколько сессий рядом (2 — колонки, 3–4 — сетка 2×2 и т. д.).
/// Сверху — тонкая панель: разделить с хостом, поиск по истории, размер шрифта.
internal sealed class TileHost : UserControl, IDisposable
{
    private sealed record Pane(TerminalView View, SshSession Session, string Alias, Border Frame, TextBlock Title);

    private readonly List<Pane> panes = new();
    private readonly Grid grid = new();
    private readonly AutoSuggestBox search = new() { Width = 260, QueryIcon = new SymbolIcon(Symbol.Find), Visibility = Visibility.Collapsed };
    private Pane? active;
    private int searchFrom = int.MaxValue;

    public event Action<string>? TitleChanged;
    public event Action<bool>? AliveChanged;

    public TerminalView? Active => active?.View;
    public bool Contains(TerminalView v) => panes.Any(p => p.View == v);

    public TileHost()
    {
        var split = new DropDownButton { Content = new FontIcon { Glyph = "", FontSize = 14 }, Padding = new Thickness(8, 4, 8, 4) };
        ToolTipService.SetToolTip(split, L("Разделить: открыть рядом ещё один терминал"));
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            foreach (var h in AppState.Hosts)
            {
                var i = new MenuFlyoutItem { Text = h.alias };
                i.Click += (_, _) => Add(h.alias);
                menu.Items.Add(i);
            }
        };
        split.Flyout = menu;
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
                split,
            },
        };
        var root = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() } };
        root.Children.Add(bar);
        Grid.SetRow(grid, 1);
        root.Children.Add(grid);
        Content = root;
        KeyboardAccelerators.Add(Accel(VirtualKey.F, () => OpenSearch()));
        KeyboardAccelerators.Add(Accel(VirtualKey.D, () => { if (active != null) Add(active.Alias); }));
        KeyboardAccelerators.Add(Accel(VirtualKey.W, () => { if (active != null && panes.Count > 1) Close(active); }));
    }

    private static KeyboardAccelerator Accel(VirtualKey key, Action action)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift };
        a.Invoked += (_, e) => { e.Handled = true; action(); };
        return a;
    }

    public void Add(string alias, string? initialInput = null)
    {
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
        session.PasswordRequested += () => DispatcherQueue.TryEnqueue(() => ask.IsOpen = true);
        var body = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() { Height = GridLength.Auto }, new() } };
        body.Children.Add(header);
        Grid.SetRow(ask, 1);
        body.Children.Add(ask);
        Grid.SetRow(view, 2);
        body.Children.Add(view);
        var frame = new Border { Child = body, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Margin = new Thickness(2) };
        var pane = new Pane(view, session, alias, frame, title);
        close.Click += (_, _) => Close(pane);
        view.GotFocus += (_, _) => Activate(pane);
        session.StateChanged += alive => AliveChanged?.Invoke(alive);
        var started = false;
        view.Loaded += (_, _) =>
        {
            if (started) return;
            started = true;
            session.Start();
            if (initialInput != null) TypeWhenReady(view, initialInput);
            view.Focus(FocusState.Programmatic);
        };
        panes.Add(pane);
        Layout();
        Activate(pane);
    }

    // Команда для новой сессии (сниппет, логи Docker, tmux attach) — после того как ssh вошёл и что-то вывел.
    private static async void TypeWhenReady(TerminalView view, string text)
    {
        for (var i = 0; i < 40; i++)
        {
            await System.Threading.Tasks.Task.Delay(250);
            var s = view.Emulator.Snapshot();
            if (s.cursorCol > 1 && view.Emulator.ScreenText().Any(l => l.TrimEnd().EndsWith('$') || l.TrimEnd().EndsWith('#') || l.TrimEnd().EndsWith('>') || l.TrimEnd().EndsWith('%')))
                break;
        }
        if (text.EndsWith('\r')) view.Type(text); else view.Paste(text);
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
        Layout();
        if (panes.Count > 0) { Activate(panes[^1]); panes[^1].View.Focus(FocusState.Programmatic); }
    }

    // Сетка: столбцов — ceil(sqrt(n)), строк — сколько нужно; заголовки плиток видны, только когда плиток больше одной.
    private void Layout()
    {
        grid.Children.Clear();
        grid.RowDefinitions.Clear();
        grid.ColumnDefinitions.Clear();
        var n = panes.Count;
        if (n == 0) return;
        var cols = (int)Math.Ceiling(Math.Sqrt(n));
        var rows = (int)Math.Ceiling(n / (double)cols);
        for (var c = 0; c < cols; c++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        for (var r = 0; r < rows; r++) grid.RowDefinitions.Add(new RowDefinition());
        for (var i = 0; i < n; i++)
        {
            var p = panes[i];
            ((Grid)((Grid)p.Frame.Child).Children[0]).Visibility = n > 1 ? Visibility.Visible : Visibility.Collapsed;
            p.Frame.BorderThickness = new Thickness(n > 1 ? 1 : 0);
            p.Frame.Margin = new Thickness(n > 1 ? 2 : 0);
            Grid.SetRow(p.Frame, i / cols);
            Grid.SetColumn(p.Frame, i % cols);
            // Последняя плитка неполного ряда растягивается на остаток.
            Grid.SetColumnSpan(p.Frame, i == n - 1 ? cols - i % cols : 1);
            grid.Children.Add(p.Frame);
        }
    }

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
