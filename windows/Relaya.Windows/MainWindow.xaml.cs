using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.relaya_core;

namespace Relaya;

public sealed partial class MainWindow : Window
{
    private static readonly string SshConfig =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "config");

    private List<SshHost> hosts = new();

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        ConfigPath.Text = SshConfig;
        LoadHosts();
    }

    // ~/.ssh/config — источник правды, как на Mac; разбирает общее Rust-ядро.
    private void LoadHosts()
    {
        var text = File.Exists(SshConfig) ? File.ReadAllText(SshConfig) : "";
        hosts = RelayaCoreMethods.ParseConfig(text)
            .Where(h => !RelayaCoreMethods.IsPattern(h.alias) && !RelayaCoreMethods.HostIsGitService(h))
            .ToList();
        Render("");
    }

    // Секции и группы — как сайдбар на Mac: «Хосты», внутри сворачиваемые группы.
    private void Render(string query)
    {
        Nav.MenuItems.Clear();
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = "Хосты" });
        var shown = hosts.Where(h => query.Length == 0
            || h.alias.Contains(query, StringComparison.OrdinalIgnoreCase)
            || (h.hostName ?? "").Contains(query, StringComparison.OrdinalIgnoreCase));
        foreach (var group in shown.GroupBy(h => h.group ?? ""))
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
                IsExpanded = true,
            };
            items.ForEach(folder.MenuItems.Add);
            Nav.MenuItems.Add(folder);
        }
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = "Инструменты" });
        Nav.MenuItems.Add(new NavigationViewItem { Content = "Ключи", Icon = new FontIcon { Glyph = "" } });
        Nav.MenuItems.Add(new NavigationViewItem { Content = "Туннели", Icon = new FontIcon { Glyph = "" } });
        Nav.MenuItems.Add(new NavigationViewItem { Content = "Сниппеты", Icon = new FontIcon { Glyph = "" } });
    }

    private static NavigationViewItem HostItem(SshHost h)
    {
        var item = new NavigationViewItem { Content = h.alias, Tag = h, Icon = new FontIcon { Glyph = "" } };
        ToolTipService.SetToolTip(item, RelayaCoreMethods.HostSubtitle(h));
        return item;
    }

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) =>
        Render(sender.Text.Trim());

    // Пока без терминала: вкладка-заглушка. Дальше — ConPTY + ssh.exe.
    private void OnItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer?.Tag is not SshHost h) return;
        var tab = new TabViewItem
        {
            Header = h.alias,
            IconSource = new FontIconSource { Glyph = "" },
            Content = DemoTerminal(h),
        };
        Tabs.TabItems.Add(tab);
        Tabs.SelectedItem = tab;
    }

    private void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        (args.Tab.Tag as IDisposable)?.Dispose();
        sender.TabItems.Remove(args.Tab);
    }
}
