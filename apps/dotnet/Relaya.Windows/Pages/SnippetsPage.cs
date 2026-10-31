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
        var list = AppState.Snippets.OrderBy(s => s.name).ToList();
        if (list.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("Сниппетов пока нет. Сниппет — команда, которую можно вставить в терминал; {{переменные}} спрашиваются перед вставкой."))));
        foreach (var s in list)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.Button(L("Вставить"), async () => await Insert(s)));
            actions.Children.Add(Ui.IconButton("", L("Копировать"), () => Ui.Copy(s.command)));
            actions.Children.Add(Ui.IconButton("", L("Изменить"), async () => await Edit(s)));
            actions.Children.Add(Ui.IconButton("", L("Удалить"), () =>
            {
                AppState.Snippets = AppState.Snippets.Where(x => x.id != s.id).ToList();
                Build();
            }));
            body.Children.Add(Ui.Row("", s.name, s.command + (s.tags.Count > 0 ? "   #" + string.Join(" #", s.tags) : ""), actions));
        }
    }

    private async Task Insert(Snippet s)
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
        terminal.Paste(command);
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
            Content = new StackPanel { Spacing = 10, MinWidth = 420, Children = { name, command, tags } },
            PrimaryButtonText = L("Сохранить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await d.ShowAsync() != ContentDialogResult.Primary || command.Text.Trim().Length == 0) return;
        var item = new Snippet(s?.id ?? RelayaCoreMethods.CoreNewId(), name.Text.Trim().Length > 0 ? name.Text.Trim() : command.Text.Trim(),
            command.Text, RelayaCoreMethods.SplitTags(tags.Text));
        AppState.Snippets = AppState.Snippets.Where(x => x.id != item.id).Append(item).ToList();
        Build();
    }
}
