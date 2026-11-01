using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Relaya.Platform;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Settings;

/// Параметры → Синхронизация, в стиле «Параметров» Windows 11: карточки на слое контента,
/// каждый профиль — раскрывающаяся карточка. Логика та же, что на Mac (ядро), хранилище — git или папка (OneDrive и т.п.).
internal sealed class SyncPage : UserControl
{
    // UI-очередь снимается в конструкторе (UI-поток). События приходят из фоновых потоков (ConPTY, туннели,
    // синхронизация), а свойство DispatcherQueue XAML-объекта из чужого потока в C# падает InvalidCastException.
    private readonly Microsoft.UI.Dispatching.DispatcherQueue ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();

    private readonly SyncService sync = SyncService.Shared;
    private readonly StackPanel root = new() { Spacing = 4, MaxWidth = 1000, Margin = new Thickness(36, 24, 36, 36) };
    private readonly Dictionary<string, (TextBlock Status, ProgressRing Ring, StackPanel Conflict, Button TrustKey)> rows = new();

    private static readonly (SyncItem Item, string Title)[] Items =
    {
        ((SyncItem)0, L("Хосты (~/.ssh/config)")),
        ((SyncItem)1, L("Сниппеты")),
        ((SyncItem)2, L("Туннели хостов профиля")),
        ((SyncItem)3, L("Удалённые столы")),
        ((SyncItem)4, L("Права AI-агентов")),
        ((SyncItem)5, L("SSH-ключи (зашифрованы паролем)")),
    };

    public SyncPage()
    {
        Content = new ScrollViewer { Content = root };
        // Новые предупреждения о ключах — перестроить страницу, иначе только обновить состояния профилей.
        sync.Changed += () => ui.TryEnqueue(() => { if (sync.RenamedKeys.Count != shownRenamed || sync.SkippedKeys.Count != shownSkipped) Build(); else UpdateStates(); });
        Build();
    }

    private int shownRenamed, shownSkipped;


    // Конфликт по файлам (C8, и для git тоже): ContentDialog, у каждого файла выбор «мой / с другой машины».
    private async System.Threading.Tasks.Task PickConflicts(string id)
    {
        if (sync.Profiles.FirstOrDefault(x => x.id == id) is not { } p) return;
        var list = sync.ConflictsOf(p);
        if (list.Count == 0) return;
        // Две версии рядом, как на Mac (UI-W3): слева моя, справа с другой машины, выбор — под ними.
        var panel = new StackPanel { Spacing = 16 };
        var choices = new List<(string Path, RadioButtons Box)>();
        UIElement Version(string title, string text) => new StackPanel
        {
            Spacing = 4,
            Children =
            {
                new TextBlock { Text = title, Style = Style("BodyStrongTextBlockStyle") },
                Pages.Ui.Card(new ScrollViewer
                {
                    MaxHeight = 220, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    Content = new TextBlock { Text = text, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono, Consolas") },
                }),
            },
        };
        foreach (var c in list)
        {
            var sides = new Grid { ColumnSpacing = 12, ColumnDefinitions = { new(), new() } };
            var mine = Version(L("Мой"), c.mine);
            var theirs = Version(L("С другой машины"), c.theirs);
            Grid.SetColumn((FrameworkElement)theirs, 1);
            sides.Children.Add(mine);
            sides.Children.Add(theirs);
            var box = new RadioButtons { Items = { L("Оставить мой"), L("Взять с другой машины") }, SelectedIndex = 0, MaxColumns = 2 };
            choices.Add((c.path, box));
            panel.Children.Add(new StackPanel
            {
                Spacing = 8,
                Children = { new TextBlock { Text = c.path, Style = Style("SubtitleTextBlockStyle") }, sides, box },
            });
        }
        var dialog = new ContentDialog
        {
            Title = L("Конфликт синхронизации"), Content = new ScrollViewer { Content = panel, MaxHeight = 560 },
            PrimaryButtonText = L("Применить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 960d;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await sync.Resolve(id, choices.ToDictionary(c => c.Path, c => c.Box.SelectedIndex == 0));
    }

    private void Build()
    {
        root.Children.Clear();
        rows.Clear();
        root.Children.Add(new TextBlock { Text = L("Синхронизация"), Style = Style("TitleTextBlockStyle"), Margin = new Thickness(0, 0, 0, 12) });
        root.Children.Add(new TextBlock
        {
            Text = Platform.PlatformText.SyncProfileHint(),
            TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush"), Margin = new Thickness(0, 0, 0, 12),
        });

        var pass = new PasswordBox { PlaceholderText = sync.HasPassphrase ? L("Задан — введите новый, чтобы сменить") : L("Не задан"), Width = 280 };
        var savePass = new Button { Content = L("Сохранить") };
        savePass.Click += async (_, _) =>
        {
            try { sync.SetPassphrase(pass.Password); }
            catch (Exception e) { await Pages.Ui.ShowError(XamlRoot, L("Не удалось сохранить пароль"), e.Message); return; }
            pass.Password = "";
            Build();
        };
        root.Children.Add(Card(L("Пароль шифрования ключей"),
            Platform.PlatformText.SyncPassphraseHint(),
            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { pass, savePass } }));

        // Одноимённые, но другие ключи с другой машины — сохранены рядом, не поверх (ядро, sync_take_renamed_keys).
        shownRenamed = sync.RenamedKeys.Count;
        foreach (var k in sync.RenamedKeys)
        {
            var bar = new InfoBar
            {
                Severity = InfoBarSeverity.Warning, IsOpen = true, IsClosable = true, Margin = new Thickness(0, 8, 0, 0),
                Message = L("Ключ %@ с другой машины отличается от вашего — сохранён как %@", k.name, k.savedAs),
            };
            bar.Closed += (_, _) => sync.DismissRenamed(k);
            root.Children.Add(bar);
        }

        shownSkipped = sync.SkippedKeys.Count;
        foreach (var (reason, key) in new[]
        {
            (KeySkipReason.NoPassphrase, "Ключи не загружены — задайте пароль шифрования ключей (тот же, что на другой машине): %@"),
            (KeySkipReason.WrongPassphrase, "Ключи не загружены — пароль шифрования ключей не подошёл: %@"),
        })
        {
            var names = sync.SkippedKeys.Where(k => k.reason == reason).Select(k => k.name).ToList();
            if (names.Count == 0) continue;
            var toPass = new Button { Content = L("Пароль шифрования ключей") };
            toPass.Click += (_, _) => { pass.StartBringIntoView(); pass.Focus(FocusState.Programmatic); };
            root.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Warning, IsOpen = true, IsClosable = true, Margin = new Thickness(0, 8, 0, 0),
                Message = L(key, string.Join(", ", names)), ActionButton = toPass,
            });
        }

        root.Children.Add(new TextBlock { Text = L("Профили"), Style = Style("BodyStrongTextBlockStyle"), Margin = new Thickness(0, 16, 0, 4) });
        foreach (var p in sync.Profiles) root.Children.Add(ProfileCard(p));

        var add = new Button { Content = L("Новый профиль"), Margin = new Thickness(0, 8, 0, 0) };
        add.Click += (_, _) => { sync.Add(); Build(); };
        var all = new Button { Content = L("Синхронизировать всё"), Margin = new Thickness(8, 8, 0, 0) };
        all.Click += async (_, _) => await sync.SyncAll();
        root.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { add, all } });
        UpdateStates();
    }

    private UIElement ProfileCard(SyncProfile initial)
    {
        var id = initial.id;
        SyncProfile Current() => sync.Profiles.First(x => x.id == id);
        void Change(Func<SyncProfile, SyncProfile> f) => sync.Update(f(Current()));

        var status = new TextBlock { Foreground = Brush("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        var ring = new ProgressRing { Width = 20, Height = 20, IsActive = false, Visibility = Visibility.Collapsed };
        var enabled = new ToggleSwitch { IsOn = initial.enabled, OnContent = "", OffContent = "", MinWidth = 0 };
        enabled.Toggled += (_, _) => Change(p => p with { enabled = enabled.IsOn });

        var name = new TextBox { Header = L("Название"), Text = initial.name };
        name.LostFocus += (_, _) => Change(p => p with { name = name.Text.Trim().Length > 0 ? name.Text.Trim() : p.name });

        var backend = new ComboBox { Header = L("Где хранить"), Items = { L("Git-репозиторий"), Platform.PlatformText.SyncFolderOption() },
            SelectedIndex = initial.backend == SyncBackend.Git ? 0 : 1, MinWidth = 280 };
        var remote = new TextBox { Text = initial.remote };
        void RemoteHeader() => remote.Header = backend.SelectedIndex == 0
            ? L("Репозиторий (git@server:relaya.git) — доступ вашими ключами из ~/.ssh")
            : Platform.PlatformText.SyncFolderPath();
        RemoteHeader();
        backend.SelectionChanged += (_, _) =>
        {
            RemoteHeader();
            Change(p => p with { backend = backend.SelectedIndex == 0 ? SyncBackend.Git : (SyncBackend)1 });
        };
        remote.LostFocus += (_, _) => Change(p => p with { remote = remote.Text.Trim() });

        var allHosts = new ToggleSwitch { Header = L("Все хосты"), IsOn = initial.scope.allHosts };
        var groups = new TextBox { Header = L("Группы и хосты через запятую (если не «все»)"),
            Text = string.Join(", ", initial.scope.groups.Concat(initial.scope.hosts)), IsEnabled = !initial.scope.allHosts };
        allHosts.Toggled += (_, _) => { groups.IsEnabled = !allHosts.IsOn; Change(p => p with { scope = p.scope with { allHosts = allHosts.IsOn } }); };
        groups.LostFocus += (_, _) =>
        {
            // Что из списка — группа, а что — хост, решаем по ~/.ssh/config.
            var names = groups.Text.Split(',').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
            var known = MainWindow.KnownGroups();
            Change(p => p with { scope = p.scope with
            {
                groups = names.Where(known.Contains).ToList(), hosts = names.Where(n => !known.Contains(n)).ToList(),
            } });
        };

        var items = new StackPanel { Spacing = 0 };
        items.Children.Add(new TextBlock { Text = L("Что синхронизировать"), Margin = new Thickness(0, 8, 0, 4) });
        foreach (var (item, title) in Items)
        {
            var box = new CheckBox { Content = title, IsChecked = initial.items.Contains(item) };
            box.Click += (_, _) => Change(p => p with
            {
                items = box.IsChecked == true ? p.items.Append(item).Distinct().ToList() : p.items.Where(i => i != item).ToList(),
            });
            items.Children.Add(box);
        }

        var auto = new ToggleSwitch { Header = L("Автоматически каждые 10 минут"), IsOn = initial.auto };
        auto.Toggled += (_, _) => Change(p => p with { auto = auto.IsOn });

        var syncNow = new Button { Content = L("Синхронизировать"), Style = Style("AccentButtonStyle") };
        syncNow.Click += async (_, _) => await sync.Sync(id);
        var delete = new Button { Content = L("Удалить профиль") };
        delete.Click += async (_, _) =>
        {
            if (!await Pages.Ui.Confirm(XamlRoot, L("Удалить профиль %@?", Current().name),
                L("Профиль синхронизации будет удалён. Хосты и файлы на этой машине не затрагиваются."), L("Удалить"))) return;
            sync.Remove(id);
            Build();
        };

        var keepMine = new Button { Content = L("Оставить мои") };
        keepMine.Click += async (_, _) => await sync.Resolve(id, keepMine: true);
        var takeTheirs = new Button { Content = L("Взять с сервера") };
        takeTheirs.Click += async (_, _) => await sync.Resolve(id, keepMine: false);
        var pick = new Button { Content = L("Разобрать по файлам…") };
        pick.Click += async (_, _) => await PickConflicts(id);
        var conflict = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed,
            Children = { keepMine, takeTheirs, pick } };

        // 11.10: git-сервер ещё не знаком — терминал к нему, отпечаток подтверждается в окне первого подключения.
        var trustKey = new Button { Content = L("Подтвердить ключ сервера…"), Visibility = Visibility.Collapsed };
        trustKey.Click += (_, _) =>
        {
            if (RepoDestination(Current().remote) is { } dest) MainWindow.Current?.OpenSession(dest);
        };
        rows[id] = (status, ring, conflict, trustKey);

        var header = new Grid { ColumnDefinitions = { new() { Width = GridLength.Auto }, new(), new() { Width = GridLength.Auto } } };
        var icon = new FontIcon { Glyph = "\uE895", FontSize = Pages.Ui.IconLarge, Margin = new Thickness(0, 0, 16, 0) };
        var titles = new StackPanel { Children = { new TextBlock { Text = initial.name }, new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8, Children = { ring, status },
        } } };
        Grid.SetColumn(titles, 1);
        Grid.SetColumn(enabled, 2);
        header.Children.Add(icon);
        header.Children.Add(titles);
        header.Children.Add(enabled);

        return new Expander
        {
            Header = header,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = new StackPanel
            {
                Spacing = 12,
                Children =
                {
                    name, backend, remote, allHosts, groups, items, auto, conflict, trustKey,
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { syncNow, delete } },
                },
            },
        };
    }

    private void UpdateStates()
    {
        foreach (var p in sync.Profiles)
        {
            if (!rows.TryGetValue(p.id, out var row)) continue;
            var (state, message) = sync.StateOf(p);
            row.Ring.IsActive = state == SyncService.State.Syncing;
            row.Ring.Visibility = state == SyncService.State.Syncing ? Visibility.Visible : Visibility.Collapsed;
            row.Status.Text = state switch
            {
                SyncService.State.Syncing => L("Синхронизация…"),
                _ => message ?? (p.enabled ? L("Ещё не синхронизирован") : L("Выключен")),
            };
            row.Status.Foreground = state is SyncService.State.Failed or SyncService.State.Conflict
                ? Brush("SystemFillColorCriticalBrush") : Brush("TextFillColorSecondaryBrush");
            row.Conflict.Visibility = state == SyncService.State.Conflict ? Visibility.Visible : Visibility.Collapsed;
            row.TrustKey.Visibility = state == SyncService.State.Failed && p.backend == SyncBackend.Git
                && message?.Contains(L("Сервер ещё не знаком")) == true ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    // Куда ssh: `git@host:path` → `git@host`; `ssh://user@host:port/path` → `ssh://user@host:port`.
    private static string? RepoDestination(string remote)
    {
        var r = remote.Trim();
        if (r.StartsWith("ssh://", StringComparison.OrdinalIgnoreCase))
        {
            var slash = r.IndexOf('/', "ssh://".Length);
            return slash > 0 ? r[..slash] : r;
        }
        var colon = r.IndexOf(':');
        return colon > 0 && !r.Contains("://") ? r[..colon] : null;
    }

    private static Border Card(string title, string description, UIElement control)
    {
        var grid = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto } }, ColumnSpacing = 16 };
        var text = new StackPanel { Children =
        {
            new TextBlock { Text = title },
            new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap, Style = Style("CaptionTextBlockStyle"),
                Foreground = Brush("TextFillColorSecondaryBrush") },
        } };
        Grid.SetColumn((FrameworkElement)control, 1);
        grid.Children.Add(text);
        grid.Children.Add(control);
        return new Border
        {
            Child = grid, Padding = new Thickness(16), CornerRadius = new CornerRadius(4),
            Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
    }

    private static Style Style(string key) => (Style)Application.Current.Resources[key];
    private static Brush Brush(string key) => (Brush)Application.Current.Resources[key];
}
