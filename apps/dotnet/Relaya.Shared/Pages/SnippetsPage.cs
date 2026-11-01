using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Сниппеты: команды с переменными {{имя}}. «Вставить» — в последний открытый терминал (без Enter), как на Mac.
internal sealed class SnippetsPage : UserControl
{
    public SnippetsPage() => Build();

    private void Build()
    {
        var (page, body) = Ui.Scaffold(L("Сниппеты"), Ui.Button(L("Новый сниппет"), async () => await Edit(null), accent: true, glyph: ""));
        Content = page;
        Ui.UnreadableBar(body, "snippets.json");
        var list = AppState.Snippets.OrderBy(s => s.name).ToList();
        if (list.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("Сниппетов пока нет. Сниппет — команда, которую можно вставить в терминал; {{переменные}} спрашиваются перед вставкой."))));
        foreach (var s in list)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.Button(L("Вставить"), async () => await Insert(s, run: false)));
            // «Выполнить» — вставить и нажать Enter (5.3), как на Mac.
            actions.Children.Add(Ui.Button(L("Выполнить"), async () => await Insert(s, run: true)));
            actions.Children.Add(Ui.Button(L("На хостах…"), async () => await RunOnHosts(s)));
            actions.Children.Add(Ui.IconButton("", L("Копировать"), () => Ui.Copy(s.command)));
            actions.Children.Add(Ui.IconButton("", L("Изменить"), async () => await Edit(s)));
            actions.Children.Add(Ui.IconButton("", L("Удалить"), async () =>
            {
                if (!await Ui.Confirm(XamlRoot, L("Удалить %@?", s.name), L("Сниппет будет удалён."), L("Удалить"))) return;
                AppState.Snippets = AppState.Snippets.Where(x => x.id != s.id).ToList();
                Build();
            }));
            body.Children.Add(Ui.Row("", s.name, s.command + (s.tags.Count > 0 ? "   #" + string.Join(" #", s.tags) : ""), actions));
        }
    }

    private async Task Insert(Snippet s, bool run)
    {
        var terminal = MainWindow.Current?.LastTerminal;
        if (terminal == null)
        {
            await Platform.DesktopLauncher.Message(XamlRoot, L("Откройте терминал хоста, чтобы вставить сниппет."));
            return;
        }
        var command = s.command;
        var variables = RelayaCoreMethods.SnippetVariables(command);
        if (variables.Count > 0)
        {
            var boxes = variables.Select(v => new TextBox { Header = v }).ToList();
            var panel = new StackPanel { Spacing = 8 };
            boxes.ForEach(panel.Children.Add);
            var d = new ContentDialog
            {
                Title = s.name, Content = panel, PrimaryButtonText = L("Вставить"), CloseButtonText = L("Отмена"),
                DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
            };
            if (await d.ShowAsync() != ContentDialogResult.Primary) return;
            command = RelayaCoreMethods.SnippetFilled(command, variables.Zip(boxes).ToDictionary(x => x.First, x => x.Second.Text));
        }
        MainWindow.Current!.SelectTerminal(terminal);
        if (run) terminal.Type(command.TrimEnd('\r', '\n') + "\r"); else terminal.Paste(command);
    }

    // «На хостах…» (5.4): одна команда на нескольких хостах без терминала, вывод каждого — в итоговом окне.
    private async Task RunOnHosts(Snippet s)
    {
        var boxes = AppState.Hosts.Select(h => new CheckBox { Content = h.alias, Tag = h.alias }).ToList();
        var list = new StackPanel { Spacing = 4 };
        boxes.ForEach(list.Children.Add);
        var command = s.command;
        var variables = RelayaCoreMethods.SnippetVariables(command);
        var fields = variables.Select(v => new TextBox { Header = v }).ToList();
        var content = new StackPanel { Spacing = 12, MinWidth = 420 };
        fields.ForEach(content.Children.Add);
        content.Children.Add(new ScrollViewer { Content = list, MaxHeight = 320 });
        var ask = new ContentDialog
        {
            Title = L("Выполнить «%@» на хостах", s.name), Content = content,
            PrimaryButtonText = L("Выполнить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot,
        };
        if (await ask.ShowAsync() != ContentDialogResult.Primary) return;
        var hosts = boxes.Where(b => b.IsChecked == true).Select(b => (string)b.Tag).ToList();
        if (hosts.Count == 0) return;
        if (variables.Count > 0) command = RelayaCoreMethods.SnippetFilled(command, variables.Zip(fields).ToDictionary(x => x.First, x => x.Second.Text));
        var results = await Task.WhenAll(hosts.Select(async h => (Host: h, Result: await AppState.RunOnHost(h, command, 120))));
        var report = new StackPanel { Spacing = 12 };
        foreach (var (h, r) in results)
        {
            report.Children.Add(new TextBlock { Text = $"{h} · " + (r.Status == 0 ? L("готово") : L("код %@", r.Status)), Style = Ui.Style("BodyStrongTextBlockStyle") });
            report.Children.Add(Ui.Card(new TextBlock
            {
                Text = (r.Stdout + r.Stderr).Trim() is { Length: > 0 } o ? o : L("(нет вывода)"), IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            }));
        }
        var done = new ContentDialog { Title = s.name, Content = new ScrollViewer { Content = report, MaxHeight = 480 }, CloseButtonText = L("Закрыть"), XamlRoot = XamlRoot };
        done.Resources["ContentDialogMaxWidth"] = 900d;
        await done.ShowAsync();
    }

    private async Task Edit(Snippet? s)
    {
        var name = new TextBox { Header = L("Название"), Text = s?.name ?? "" };
        var command = new TextBox
        {
            Header = L("Команда ({{переменная}} — спросить при вставке)"), Text = s?.command ?? "", AcceptsReturn = true, MinHeight = 100,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        };
        var tags = new TextBox { Header = L("Метки через запятую"), Text = s == null ? "" : string.Join(", ", s.tags) };
        var d = new ContentDialog
        {
            Title = s == null ? L("Новый сниппет") : L("Изменить сниппет"),
            Content = new StackPanel { Spacing = 12, MinWidth = 420, Children = { name, command, tags } },
            PrimaryButtonText = L("Сохранить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await d.ShowAsync() != ContentDialogResult.Primary || command.Text.Trim().Length == 0) return;
        var item = new Snippet(s?.id ?? RelayaCoreMethods.CoreNewId(), name.Text.Trim().Length > 0 ? name.Text.Trim() : command.Text.Trim(),
            command.Text, RelayaCoreMethods.SplitTags(tags.Text));
        AppState.Snippets = AppState.Snippets.Where(x => x.id != item.id).Append(item).ToList();
        Build();
    }
}
