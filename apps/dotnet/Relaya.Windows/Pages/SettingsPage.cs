using System;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Relaya.Terminal;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Параметры: Терминал (тема, шрифт), Синхронизация, О программе — вкладки SelectorBar, как в приложениях Windows 11.
internal sealed class SettingsPage : UserControl
{
    private readonly ContentControl body = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private Settings.SyncPage? sync;

    public SettingsPage()
    {
        var bar = new SelectorBar { Margin = new Thickness(28, 16, 28, 0) };
        var terminal = new SelectorBarItem { Text = L("Терминал"), IsSelected = true };
        var syncItem = new SelectorBarItem { Text = L("Синхронизация") };
        var about = new SelectorBarItem { Text = L("О программе") };
        bar.Items.Add(terminal);
        bar.Items.Add(syncItem);
        bar.Items.Add(about);
        bar.SelectionChanged += (_, _) =>
        {
            body.Content = bar.SelectedItem == syncItem ? (sync ??= new Settings.SyncPage())
                : bar.SelectedItem == about ? About() : Terminal();
        };
        body.Content = Terminal();
        var root = new Grid { RowDefinitions = { new() { Height = GridLength.Auto }, new() } };
        root.Children.Add(bar);
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        Content = root;
    }

    private static UIElement Terminal()
    {
        var (page, list) = Ui.Scaffold(L("Терминал"));
        var theme = new ComboBox { MinWidth = 220 };
        foreach (var n in TerminalTheme.Names) theme.Items.Add(n);
        theme.SelectedItem = Platform.Settings.Get("terminal.theme", "Relaya");
        var preview = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(12), Margin = new Thickness(0, 4, 0, 0) };
        void Preview()
        {
            var t = TerminalTheme.Named(theme.SelectedItem as string ?? "Relaya");
            var lines = new StackPanel();
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            for (var i = 0; i < 16; i++)
                row.Children.Add(new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(t.Ansi[i]) });
            lines.Children.Add(new TextBlock
            {
                Text = "user@server:~$ ls --color", Foreground = new SolidColorBrush(t.Foreground),
                FontFamily = new FontFamily(Platform.Settings.Get("terminal.font", "Cascadia Mono")), Margin = new Thickness(0, 0, 0, 8),
            });
            lines.Children.Add(row);
            preview.Background = new SolidColorBrush(t.Background);
            preview.Child = lines;
        }
        theme.SelectionChanged += (_, _) => { Platform.Settings.Set("terminal.theme", theme.SelectedItem as string ?? "Relaya"); Preview(); };
        list.Children.Add(Ui.Row("", L("Тема"), L("Цвета терминала во всех вкладках"), theme));

        var font = new ComboBox { MinWidth = 220, IsEditable = true };
        foreach (var f in new[] { "Cascadia Mono", "Cascadia Code", "Consolas", "Lucida Console", "JetBrains Mono", "Fira Code" }) font.Items.Add(f);
        font.Text = Platform.Settings.Get("terminal.font", "Cascadia Mono");
        void SetFont(string? f) { if (!string.IsNullOrWhiteSpace(f)) { Platform.Settings.Set("terminal.font", f.Trim()); Preview(); } }
        font.SelectionChanged += (_, _) => SetFont(font.SelectedItem as string);
        font.TextSubmitted += (_, e) => SetFont(e.Text);
        list.Children.Add(Ui.Row("", L("Шрифт"), L("Моноширинный; установленные в системе шрифты тоже подходят"), font));

        var size = new NumberBox { Minimum = 8, Maximum = 32, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            Value = double.TryParse(Platform.Settings.Get("terminal.size", "14"), out var v) ? v : 14 };
        size.ValueChanged += (_, _) => Platform.Settings.Set("terminal.size", ((int)size.Value).ToString());
        list.Children.Add(Ui.Row("", L("Размер шрифта"), L("Также Ctrl+= и Ctrl+− в терминале"), size));
        list.Children.Add(preview);
        Preview();

        var idle = new NumberBox { Minimum = 1, Maximum = 10080, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            Value = double.TryParse(Platform.Settings.Get("tmux.idle", "60"), out var t) ? t : 60 };
        idle.ValueChanged += (_, _) => Platform.Settings.Set("tmux.idle", ((int)idle.Value).ToString());
        list.Children.Add(Ui.Row("\uE8A1", L("tmux: закрывать брошенные сессии через, мин"),
            L("Для хостов с tmux: сессия без подключений живёт на сервере столько минут"), idle));

        list.Children.Add(Ui.Section(L("Клавиши")));
        foreach (var (k, d) in new[]
        {
            ("Ctrl+Shift+C / Ctrl+Shift+V", L("Копировать / вставить")),
            (L("Правый клик"), L("Копировать выделение или вставить")),
            ("Ctrl+" + L("клик"), L("Открыть ссылку")),
            ("Ctrl+Shift+F", L("Поиск по выводу")),
            ("Ctrl+Shift+D / Ctrl+Shift+W", L("Разделить / закрыть плитку")),
            ("Ctrl+W, Ctrl+Tab", L("Закрыть вкладку, следующая вкладка")),
            ("Ctrl+K", L("Поиск хостов (Enter — подключиться)")),
        })
            list.Children.Add(Ui.Row(null, k, d));
        return page;
    }

    private static UIElement About()
    {
        var (page, list) = Ui.Scaffold(L("О программе"));
        var version = typeof(SettingsPage).Assembly.GetName().Version?.ToString(3) ?? "";
        list.Children.Add(Ui.Row("", "Relaya " + version, L("Бесплатный SSH-клиент с открытым кодом (MIT). ~/.ssh — источник правды.")));
        list.Children.Add(Ui.Row("", "GitHub", "https://github.com/hvckfy/Relaya",
            Ui.Button(L("Открыть"), () => _ = Windows.System.Launcher.LaunchUriAsync(new System.Uri("https://github.com/hvckfy/Relaya")))));
        list.Children.Add(Ui.Row("", L("Ядро"), "relaya-core " + uniffi.relaya_core.RelayaCoreMethods.CoreVersion()));
        list.Children.Add(Ui.Row("", L("Файлы"), Data.AppState.ConfigPath + "\n" + Data.AppState.Support,
            Ui.Button(L("Открыть папку"), () => System.Diagnostics.Process.Start("explorer.exe", Data.AppState.Support))));
        return page;
    }
}
