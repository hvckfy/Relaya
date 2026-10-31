using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Relaya.Platform;
using uniffi.relaya_core;

namespace Relaya.Settings;

/// Параметры → Синхронизация, в стиле «Параметров» Windows 11: карточки на слое контента,
/// каждый профиль — раскрывающаяся карточка. Логика та же, что на Mac (ядро), хранилище — git или папка (OneDrive и т.п.).
internal sealed class SyncPage : UserControl
{
    private readonly SyncService sync = SyncService.Shared;
    private readonly StackPanel root = new() { Spacing = 4, MaxWidth = 1000, Margin = new Thickness(36, 24, 36, 36) };
    private readonly Dictionary<string, (TextBlock Status, ProgressRing Ring, StackPanel Conflict)> rows = new();

    private static readonly (SyncItem Item, string Title)[] Items =
    {
        ((SyncItem)0, "Хосты (~/.ssh/config)"),
        ((SyncItem)1, "Сниппеты"),
        ((SyncItem)2, "Туннели хостов профиля"),
        ((SyncItem)3, "Удалённые столы"),
        ((SyncItem)4, "Права AI-агентов"),
        ((SyncItem)5, "SSH-ключи (зашифрованы паролем)"),
    };

    public SyncPage()
    {
        Content = new ScrollViewer { Content = root };
        sync.Changed += () => DispatcherQueue.TryEnqueue(UpdateStates);
        Build();
    }

    private void Build()
    {
        root.Children.Clear();
        rows.Clear();
        root.Children.Add(new TextBlock { Text = "Синхронизация", Style = Style("TitleTextBlockStyle"), Margin = new Thickness(0, 0, 0, 12) });
        root.Children.Add(new TextBlock
        {
            Text = "Профиль — ваш git-репозиторий или папка (OneDrive, сетевой диск) и набор хостов. Пароли серверов не синхронизируются никогда.",
            TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush"), Margin = new Thickness(0, 0, 0, 12),
        });

        var pass = new PasswordBox { PlaceholderText = sync.HasPassphrase ? "Задан — введите новый, чтобы сменить" : "Не задан", Width = 280 };
        var savePass = new Button { Content = "Сохранить" };
        savePass.Click += (_, _) => { sync.SetPassphrase(pass.Password); pass.Password = ""; Build(); };
        root.Children.Add(Card("Пароль шифрования ключей",
            "Нужен, чтобы передавать SSH-ключи. Одинаковый на всех устройствах. Хранится в диспетчере учётных данных Windows.",
            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { pass, savePass } }));

        root.Children.Add(new TextBlock { Text = "Профили", Style = Style("BodyStrongTextBlockStyle"), Margin = new Thickness(0, 16, 0, 4) });
        foreach (var p in sync.Profiles) root.Children.Add(ProfileCard(p));

        var add = new Button { Content = "Новый профиль", Style = Style("AccentButtonStyle"), Margin = new Thickness(0, 8, 0, 0) };
        add.Click += (_, _) => { sync.Add(); Build(); };
        var all = new Button { Content = "Синхронизировать всё", Margin = new Thickness(8, 8, 0, 0) };
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
        var ring = new ProgressRing { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        var enabled = new ToggleSwitch { IsOn = initial.enabled, OnContent = "", OffContent = "", MinWidth = 0 };
        enabled.Toggled += (_, _) => Change(p => p with { enabled = enabled.IsOn });

        var name = new TextBox { Header = "Название", Text = initial.name };
        name.LostFocus += (_, _) => Change(p => p with { name = name.Text.Trim().Length > 0 ? name.Text.Trim() : p.name });

        var backend = new ComboBox { Header = "Где хранить", Items = { "Git-репозиторий", "Папка (OneDrive, сетевой диск)" },
            SelectedIndex = initial.backend == SyncBackend.Git ? 0 : 1, MinWidth = 280 };
        var remote = new TextBox { Text = initial.remote };
        void RemoteHeader() => remote.Header = backend.SelectedIndex == 0
            ? "Репозиторий (git@server:relaya.git) — доступ вашими ключами из ~/.ssh"
            : "Путь к папке, например C:\\Users\\you\\OneDrive\\Relaya";
        RemoteHeader();
        backend.SelectionChanged += (_, _) =>
        {
            RemoteHeader();
            Change(p => p with { backend = backend.SelectedIndex == 0 ? SyncBackend.Git : (SyncBackend)1 });
        };
        remote.LostFocus += (_, _) => Change(p => p with { remote = remote.Text.Trim() });

        var allHosts = new ToggleSwitch { Header = "Все хосты", IsOn = initial.scope.allHosts };
        var groups = new TextBox { Header = "Группы и хосты через запятую (если не «все»)",
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
        items.Children.Add(new TextBlock { Text = "Что синхронизировать", Margin = new Thickness(0, 8, 0, 4) });
        foreach (var (item, title) in Items)
        {
            var box = new CheckBox { Content = title, IsChecked = initial.items.Contains(item) };
            box.Click += (_, _) => Change(p => p with
            {
                items = box.IsChecked == true ? p.items.Append(item).Distinct().ToList() : p.items.Where(i => i != item).ToList(),
            });
            items.Children.Add(box);
        }

        var auto = new ToggleSwitch { Header = "Автоматически каждые 10 минут", IsOn = initial.auto };
        auto.Toggled += (_, _) => Change(p => p with { auto = auto.IsOn });

        var syncNow = new Button { Content = "Синхронизировать", Style = Style("AccentButtonStyle") };
        syncNow.Click += async (_, _) => await sync.Sync(id);
        var delete = new Button { Content = "Удалить профиль" };
        delete.Click += (_, _) => { sync.Remove(id); Build(); };

        var keepMine = new Button { Content = "Оставить мои" };
        keepMine.Click += async (_, _) => await sync.Resolve(id, keepMine: true);
        var takeTheirs = new Button { Content = "Взять с сервера" };
        takeTheirs.Click += async (_, _) => await sync.Resolve(id, keepMine: false);
        var conflict = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed,
            Children = { keepMine, takeTheirs } };

        rows[id] = (status, ring, conflict);

        var header = new Grid { ColumnDefinitions = { new() { Width = GridLength.Auto }, new(), new() { Width = GridLength.Auto } } };
        var icon = new FontIcon { Glyph = "\uE895", FontSize = 18, Margin = new Thickness(0, 0, 16, 0) };
        var titles = new StackPanel { Children = { new TextBlock { Text = initial.name }, new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6, Children = { ring, status },
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
                    name, backend, remote, allHosts, groups, items, auto, conflict,
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
                SyncService.State.Syncing => "Синхронизация…",
                _ => message ?? (p.enabled ? "Ещё не синхронизирован" : "Выключен"),
            };
            row.Status.Foreground = state is SyncService.State.Failed or SyncService.State.Conflict
                ? new SolidColorBrush(Microsoft.UI.Colors.IndianRed) : Brush("TextFillColorSecondaryBrush");
            row.Conflict.Visibility = state == SyncService.State.Conflict ? Visibility.Visible : Visibility.Collapsed;
        }
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
