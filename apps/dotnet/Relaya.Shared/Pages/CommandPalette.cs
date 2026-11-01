using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Relaya.Data;
using Relaya.Platform;
using uniffi.relaya_core;
using Windows.System;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Палитра команд (Ctrl+Shift+P), как Command Palette в Windows Terminal и ⌘K на Mac: одно поле, нечёткий поиск ядра
/// по хостам, удалённым столам, раскладкам, сниппетам, туннелям и действиям. ↑↓ — выбор, Enter — выполнить,
/// Ctrl+Enter — файлы (SFTP) вместо терминала, Esc — закрыть. Пустой запрос — недавние сверху (palette.recents, до 8).
internal static class CommandPalette
{
    private sealed record Item(string Id, string Title, string Subtitle, string Glyph, string Section, List<string> Fields,
        Action Run, Action? Alternate = null);

    private const int RecentLimit = 8;

    /// `snippetsOnly` — палитра сниппетов (Ctrl+Shift+S, 5.5, как ⇧⌘P на Mac): только сниппеты, вставка в активный терминал.
    public static void Show(MainWindow window, bool snippetsOnly = false)
    {
        if (window.Content is not FrameworkElement root) return;
        var all = Items(window);
        if (snippetsOnly) all = all.Where(i => i.Id.StartsWith("snippet:")).ToList();
        var box = new TextBox { PlaceholderText = snippetsOnly ? L("Сниппет…") : L("Хост, действие, сниппет…") };
        AutomationProperties.SetName(box, L("Палитра команд"));
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 360, IsItemClickEnabled = true };
        var hint = Ui.Secondary(L("↑↓ — выбрать · Enter — открыть · Ctrl+Enter — файлы · Esc — закрыть"));
        hint.Margin = new Thickness(4, 8, 4, 0);
        var flyout = new Flyout
        {
            Content = new StackPanel { Width = 600, Spacing = 4, Children = { box, list, hint } },
            Placement = FlyoutPlacementMode.Bottom,
            ShouldConstrainToRootBounds = true,
        };
        List<Item> shown = new();
        // Ctrl отслеживаем по событиям поля: общего опроса клавиатуры в Uno нет (как в TerminalView.Skia).
        var ctrl = false;

        void Fill()
        {
            shown = Results(all, box.Text.Trim());
            list.Items.Clear();
            string? section = null;
            foreach (var item in shown)
            {
                // Заголовок раздела — некликабельный элемент списка, как группы в Windows Terminal.
                if (item.Section != section)
                {
                    section = item.Section;
                    list.Items.Add(new ListViewItem
                    {
                        Content = new TextBlock { Text = section, Style = Ui.Style("CaptionTextBlockStyle"), Foreground = Ui.Brush("TextFillColorSecondaryBrush") },
                        IsEnabled = false, IsTabStop = false, MinHeight = 24,
                    });
                }
                list.Items.Add(Row(item));
            }
            Select(0, 1);
        }

        // Выбрать следующий кликабельный элемент от индекса start в направлении step.
        void Select(int start, int step)
        {
            for (var i = start; i >= 0 && i < list.Items.Count; i += step)
                if (list.Items[i] is ListViewItem { Tag: Item })
                {
                    list.SelectedIndex = i;
                    list.ScrollIntoView(list.Items[i]);
                    return;
                }
        }

        void Execute(bool alternate)
        {
            if (list.SelectedItem is not ListViewItem { Tag: Item item }) return;
            flyout.Hide();
            Remember(item.Id);
            try { if (alternate && item.Alternate is { } alt) alt(); else item.Run(); }
            catch (Exception e) { Terminal.TerminalView.Trace("palette: " + e.Message); }
        }

        box.TextChanged += (_, _) => Fill();
        box.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler((_, e) =>
        {
            if (e.Key is VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl) ctrl = false;
        }), handledEventsToo: true);
        box.KeyDown += (_, e) =>
        {
            if (e.Key is VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl) { ctrl = true; return; }
            switch (e.Key)
            {
                case VirtualKey.Down: e.Handled = true; Select(list.SelectedIndex + 1, 1); break;
                case VirtualKey.Up: e.Handled = true; Select(list.SelectedIndex - 1, -1); break;
                case VirtualKey.Enter:
                    e.Handled = true;
                    Execute(ctrl);
                    break;
            }
        };
        list.ItemClick += (_, e) => { list.SelectedItem = e.ClickedItem is ListViewItem ? e.ClickedItem : list.SelectedItem; Execute(false); };
        flyout.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        Fill();
        flyout.ShowAt(root, new FlyoutShowOptions { Placement = FlyoutPlacementMode.Top, Position = new Windows.Foundation.Point(root.ActualWidth / 2, 48) });
    }

    private static ListViewItem Row(Item item)
    {
        var text = new StackPanel { Children = { new TextBlock { Text = item.Title, Style = Ui.Style("BodyTextBlockStyle"), TextTrimming = TextTrimming.CharacterEllipsis } } };
        if (item.Subtitle.Length > 0)
            text.Children.Add(new TextBlock
            {
                Text = item.Subtitle, Style = Ui.Style("CaptionTextBlockStyle"), Foreground = Ui.Brush("TextFillColorSecondaryBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(0, 4, 0, 4), Children = { new FontIcon { Glyph = item.Glyph, FontSize = 16 }, text } };
        var lvi = new ListViewItem { Content = row, Tag = item };
        AutomationProperties.SetName(lvi, item.Title);
        return lvi;
    }

    private static List<Item> Results(List<Item> all, string query)
    {
        if (query.Length == 0)
        {
            var recentIds = Recents();
            var recent = recentIds.Select(id => all.FirstOrDefault(i => i.Id == id)).OfType<Item>()
                .Select(i => i with { Section = L("Недавние") }).ToList();
            var rest = all.Where(i => !recentIds.Contains(i.Id) && i.Section != L("Действия")).Take(12);
            return recent.Concat(rest).ToList();
        }
        return all
            .Select(i => (i, s: RelayaCoreMethods.FuzzyScoreFields(query, new[] { i.Title }.Concat(i.Fields).ToList())))
            .Where(x => x.s != null)
            .OrderByDescending(x => x.s)
            .Take(40)
            .Select(x => x.i)
            .ToList();
    }

    private static List<string> Recents() =>
        Platform.Settings.Get("palette.recents", "").Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();

    private static void Remember(string id) =>
        Platform.Settings.Set("palette.recents", string.Join("\n", new[] { id }.Concat(Recents().Where(r => r != id)).Take(RecentLimit)));

    private static List<Item> Items(MainWindow w)
    {
        var list = new List<Item>();
        foreach (var h in AppState.Hosts)
            list.Add(new Item("host:" + h.alias, h.alias, RelayaCoreMethods.HostSubtitle(h), "", L("Хосты"),
                new[] { h.hostName ?? "", h.user ?? "", h.group ?? "" }.Concat(h.tags).ToList(),
                () => w.OpenSession(h.alias), () => w.OpenSftp(h.alias)));
        foreach (var d in AppState.Desktops)
            list.Add(new Item("desktop:" + d.id, d.name, $"{(d.kind == DesktopKind.Rdp ? "RDP" : "VNC")} · {d.address}:{d.port}",
                d.kind == DesktopKind.Rdp ? "" : "", L("Удалённые столы"), new() { d.address, d.user },
                () => DesktopLauncher.Open(d, w.Content.XamlRoot)));
        foreach (var l in SavedLayouts.All())
            list.Add(new Item("layout:" + l.Id, l.Name, "", "", L("Раскладки"), new(), () => w.OpenLayout(l)));
        foreach (var s in AppState.Snippets)
            list.Add(new Item("snippet:" + s.id, s.name, s.command, "", L("Сниппеты"), new[] { s.command }.Concat(s.tags).ToList(),
                () => InsertSnippet(w, s)));
        foreach (var t in AppState.Tunnels)
        {
            var running = TunnelManager.Shared.StatusOf(t).State is TunnelManager.State.Running or TunnelManager.State.Starting;
            list.Add(new Item("tunnel:" + t.id, (running ? L("Остановить туннель") : L("Запустить туннель")) + " · " + t.name,
                $"{t.listenPort} → {t.targetHost}:{t.targetPort} ({t.hostAlias})", "", L("Туннели"), new() { t.name, t.hostAlias },
                () => { if (running) TunnelManager.Shared.Stop(t.id); else TunnelManager.Shared.Start(t); }));
        }
        void Action(string id, string title, string glyph, Action run) =>
            list.Add(new Item("action:" + id, title, "", glyph, L("Действия"), new(), run));
        Action("new-host", L("Новый хост…"), "", () => _ = HostEditor.Show(w.Content.XamlRoot, null, false));
        Action("keys", L("Ключи"), "", () => w.ShowPage(new KeysPage()));
        Action("tunnels", L("Туннели"), "", () => w.ShowPage(new TunnelsPage()));
        Action("layouts", L("Раскладки"), "", () => w.ShowPage(new LayoutsPage()));
        Action("snippets", L("Сниппеты"), "", () => w.ShowPage(new SnippetsPage()));
        Action("desktops", L("Удалённые столы"), "", () => w.ShowPage(new DesktopsPage()));
        Action("agents", L("Агенты"), "", () => w.ShowPage(new AgentsPage()));
        Action("settings", L("Параметры"), "", () => w.ShowPage(new SettingsPage()));
        Action("reload", L("Перечитать ~/.ssh/config"), "", AppState.LoadHosts);
        return list;
    }

    // Сниппет без переменных — сразу в последний терминал (как вставка, без Enter); с {{переменными}} или без
    // открытого терминала — страница сниппетов, где их заполняют.
    // Общее для палитры и панели над терминалом (Е.20); target — терминал, куда вставлять (по умолчанию последний).
    internal static void InsertSnippet(MainWindow w, Snippet s, Terminal.TerminalView? target = null)
    {
        if ((target ?? w.LastTerminal) is { } terminal && RelayaCoreMethods.SnippetVariables(s.command).Count == 0)
        {
            w.SelectTerminal(terminal);
            terminal.Paste(s.command);
            return;
        }
        w.ShowPage(new SnippetsPage());
    }
}
