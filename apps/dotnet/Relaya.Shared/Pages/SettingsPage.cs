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
        // Внешние программы и службы (Л5) — только там, где их ставит не установщик (Linux).
        var components = new SelectorBarItem { Text = L("Компоненты") };
        if (Platform.Components.List().Count > 0) bar.Items.Add(components);
        bar.SelectionChanged += (_, _) =>
        {
            body.Content = bar.SelectedItem == syncItem ? (sync ??= new Settings.SyncPage())
                : bar.SelectedItem == about ? About()
                : bar.SelectedItem == components ? ComponentsPage.Build() : Terminal();
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
        // Оформление окна (12.1): как в системе, светлое или тёмное — сразу, без перезапуска.
        var appTheme = new ComboBox { MinWidth = 220, Items = { L("Системная"), L("Светлая"), L("Тёмная") } };
        appTheme.SelectedIndex = Platform.Settings.Get("app.theme", "system") switch { "light" => 1, "dark" => 2, _ => 0 };
        appTheme.SelectionChanged += (_, _) =>
        {
            Platform.Settings.Set("app.theme", appTheme.SelectedIndex switch { 1 => "light", 2 => "dark", _ => "system" });
            MainWindow.Current?.ApplyTheme();
        };
        list.Children.Add(Ui.Row("\uE790", L("Оформление"), L("Цвета окна Relaya"), appTheme));
        var theme = new ComboBox { MinWidth = 220 };
        foreach (var n in TerminalTheme.Names) theme.Items.Add(n);
        theme.SelectedItem = Platform.Settings.Get("terminal.theme", "Relaya");
        var preview = new Border { CornerRadius = new CornerRadius(4), Padding = new Thickness(12), Margin = new Thickness(0, 4, 0, 0) };
        void Preview()
        {
            var t = TerminalTheme.Named(theme.SelectedItem as string ?? "Relaya");
            var lines = new StackPanel();
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            for (var i = 0; i < 16; i++)
                row.Children.Add(new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(t.Ansi[i]) });
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

        var highlight = new ToggleSwitch { IsOn = Platform.Settings.Get("terminal.highlight", "1") == "1", OnContent = "", OffContent = "", MinWidth = 0 };
        highlight.Toggled += (_, _) => Platform.Settings.Set("terminal.highlight", highlight.IsOn ? "1" : "0");
        list.Children.Add(Ui.Row("\uE7E6", L("Подсветка вывода"), L("Ошибки, предупреждения, успех, IP-адреса и ссылки — цветами темы; полноэкранные программы не трогаются"), highlight));

        var idle = new NumberBox { Minimum = 1, Maximum = 10080, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            Value = double.TryParse(Platform.Settings.Get("tmux.idle", "60"), out var t) ? t : 60 };
        idle.ValueChanged += (_, _) => Platform.Settings.Set("tmux.idle", ((int)idle.Value).ToString());
        list.Children.Add(Ui.Row("\uE8A1", L("tmux: закрывать брошенные сессии через, мин"),
            L("Для хостов с tmux: сессия без подключений живёт на сервере столько минут"), idle));

        // H.264 для встроенного RDP (9.12): только где ядро на FreeRDP и не Windows (там Media Foundation).
        if (Platform.OpenH264.Available) list.Children.Add(H264Row());

#if HAS_UNO
        // Значок туннелей (12.5), как «Значок туннелей в строке меню» на Mac; на Windows трея пока нет.
        var tray = new ToggleSwitch { IsOn = Platform.TrayIcon.Enabled, OnContent = "", OffContent = "", MinWidth = 0 };
        tray.Toggled += (_, _) => { Platform.Settings.Set("tray.enabled", tray.IsOn ? "1" : "0"); Platform.TrayIcon.Refresh(); };
        list.Children.Add(Ui.Row("\uE8A7", L("Значок туннелей в области уведомлений"), L("Показывается, когда есть туннели"), tray));
#endif

        list.Children.Add(Ui.Section(L("Безопасность")));
        var confirm = new ToggleSwitch { IsOn = Platform.Settings.Get("security.confirmPassword", "0") == "1", OnContent = "", OffContent = "", MinWidth = 0 };
        confirm.Toggled += (_, _) => Platform.Settings.Set("security.confirmPassword", confirm.IsOn ? "1" : "0");
        list.Children.Add(Ui.Row("\uE72E", L("Подтверждать каждое использование пароля"),
            L("Перед тем как фоновый ssh (туннель, SFTP, панели хоста, агенты) получит сохранённый пароль, Relaya спросит вас"), confirm));
        // 12.4: не спрашивать повторно N минут после подтверждения (как Touch ID на Mac).
        var grace = new ComboBox { MinWidth = 160 };
        var graceValues = new[] { 0, 1, 5, 15, 30 };
        foreach (var minutes in graceValues) grace.Items.Add(minutes == 0 ? L("спрашивать каждый раз") : L("%@ мин", minutes.ToString()));
        var current = int.TryParse(Platform.Settings.Get(Platform.ConsentGrace.Key, "0"), out var gm) ? gm : 0;
        grace.SelectedIndex = Math.Max(0, Array.IndexOf(graceValues, current));
        grace.SelectionChanged += (_, _) =>
        {
            Platform.Settings.Set(Platform.ConsentGrace.Key, graceValues[grace.SelectedIndex].ToString());
            Platform.ConsentGrace.Reset();
        };
        list.Children.Add(Ui.Row("\uE916", L("Не спрашивать повторно"),
            L("После подтверждения сохранённый пароль какое-то время выдаётся без нового вопроса"), grace));
        var offerKey = new ToggleSwitch { IsOn = Platform.Settings.Get("terminal.offerKeySetup", "1") == "1", OnContent = "", OffContent = "", MinWidth = 0 };
        offerKey.Toggled += (_, _) => Platform.Settings.Set("terminal.offerKeySetup", offerKey.IsOn ? "1" : "0");
        list.Children.Add(Ui.Row("\uE8D7", L("Предлагать вход по ключу"),
            L("После входа по паролю на хост без ключа терминал предложит настроить вход по ключу"), offerKey));

        list.Children.Add(Ui.Section(L("Клавиши")));
        foreach (var (k, d) in new[]
        {
            ("Ctrl+Shift+C / Ctrl+Shift+V", L("Копировать / вставить")),
            (L("Правый клик"), L("Копировать выделение или вставить")),
            ("Ctrl+" + L("клик"), L("Открыть ссылку")),
            ("Ctrl+Shift+F", L("Поиск по выводу")),
            ("Ctrl+Shift+D / E / W", L("Разделить вправо / вниз, закрыть плитку")),
            ("Ctrl+Alt+← ↑ → ↓", L("Соседняя плитка")),
            ("Ctrl+W, Ctrl+Tab", L("Закрыть вкладку, следующая вкладка")),
            ("Ctrl+K", L("Поиск хостов (Enter — подключиться)")),
            ("Ctrl+Shift+N, F2, F5", L("Новый хост, изменить хост, перечитать ~/.ssh/config")),
            ("Ctrl+Shift+T, Ctrl+Shift+O", L("Новая вкладка к хосту, файлы хоста")),
            ("Ctrl+Shift+R, Ctrl+Alt+1…9", L("Переподключить, вкладка по номеру")),
        })
            list.Children.Add(Ui.Row(null, k, d));
        return page;
    }

    // Включение — после согласия с условиями Cisco (по умолчанию «Отмена»), выключение удаляет библиотеку.
    private static UIElement H264Row()
    {
        var toggle = new ToggleSwitch { IsOn = Platform.OpenH264.IsInstalled, OnContent = "", OffContent = "", MinWidth = 0 };
        var status = Ui.Secondary("");
        var text = new StackPanel { Children = { status } };
        var busy = false;
        toggle.Toggled += async (_, _) =>
        {
            if (busy || toggle.IsOn == Platform.OpenH264.IsInstalled) return;
            busy = true;
            status.Text = "";
            try
            {
                if (!toggle.IsOn) { Platform.OpenH264.Remove(); return; }
                var dialog = new ContentDialog
                {
                    Title = L("Скачать OpenH264 от Cisco?"),
                    Content = new ScrollViewer { Content = new TextBlock { Text = Platform.OpenH264.Info?.notice ?? "", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }, MaxHeight = 360 },
                    PrimaryButtonText = L("Скачать и включить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Close,
                    XamlRoot = toggle.XamlRoot,
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) { toggle.IsOn = false; return; }
                toggle.IsEnabled = false;
                await Platform.OpenH264.InstallAsync();
            }
            catch (Exception e) { status.Text = e.Message; }
            finally
            {
                toggle.IsOn = Platform.OpenH264.IsInstalled;
                toggle.IsEnabled = true;
                busy = false;
            }
        };
        return Ui.Row("\uE714", L("H.264 для удалённых столов (OpenH264 от Cisco)"),
            L("Чётче и быстрее на медленном канале. Кодек скачивается с сервера Cisco и проверяется по отпечатку."),
            new StackPanel { Spacing = 4, Children = { toggle, text } });
    }

    private static UIElement About()
    {
        var (page, list) = Ui.Scaffold(L("О программе"));
        var version = typeof(SettingsPage).Assembly.GetName().Version?.ToString(3) ?? "";
        list.Children.Add(Ui.Row("", "Relaya " + version, L("Бесплатный SSH-клиент с открытым кодом (MIT). ~/.ssh — источник правды.")));
        list.Children.Add(Ui.Row("", "GitHub", "https://github.com/hvckfy/Relaya",
            Ui.Button(L("Открыть"), () => _ = Windows.System.Launcher.LaunchUriAsync(new System.Uri("https://github.com/hvckfy/Relaya")))));
        list.Children.Add(Ui.Row("", L("Ядро"), "relaya-core " + uniffi.relaya_core.RelayaCoreMethods.CoreVersion()));
        var logSize = new NumberBox
        {
            Minimum = Platform.LogFiles.MinKB, Maximum = Platform.LogFiles.MaxKB, SmallChange = 64, LargeChange = 1024,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, Value = Platform.LogFiles.LimitKB,
        };
        logSize.ValueChanged += (_, e) => { if (!double.IsNaN(e.NewValue)) Platform.Settings.Set("logs.maxKB", ((int)e.NewValue).ToString()); };
        list.Children.Add(Ui.Row("\uE9D9", L("Максимальный размер журналов, КБ"),
            L("terminal.log и журнал агентов: переросший файл становится .old, запись продолжается в новый"), logSize));
        list.Children.Add(Ui.Row("\uE838", L("Журналы"), Data.AppState.Support,
            Ui.Button(L("Открыть папку журналов"), () => Platform.Shell.OpenFolder(Data.AppState.Support))));
        list.Children.Add(Ui.Row("", L("Файлы"), Data.AppState.ConfigPath + "\n" + Data.AppState.Support,
            Ui.Button(L("Открыть папку"), () => Platform.Shell.OpenFolder(Data.AppState.Support))));
        return page;
    }
}
