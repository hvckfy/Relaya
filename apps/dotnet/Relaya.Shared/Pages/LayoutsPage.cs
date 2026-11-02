using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Сохранённые раскладки плиток (layouts.json, общий с Mac): открыть одной вкладкой, переименовать, удалить.
/// Сохраняются из меню вкладки терминала — «Сохранить раскладку…».
internal sealed class LayoutsPage : UserControl
{
    public LayoutsPage() => Build();

    private void Build()
    {
        var (page, body) = Ui.Scaffold(L("Раскладки"));
        Content = page;
        var list = SavedLayouts.All().OrderBy(s => s.Name).ToList();
        if (list.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("Раскладок пока нет. Разложите терминалы плитками и выберите «Сохранить раскладку…» в меню вкладки."))));
        foreach (var s in list)
        {
            var hosts = Hosts(s.Layout);
            var missing = hosts.Where(h => AppState.Host(h) == null).ToList();
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.Button(L("Открыть"), () => MainWindow.Current?.OpenLayout(s), accent: true));
            actions.Children.Add(Ui.IconButton("", L("Переименовать"), async () => await Rename(s)));
            actions.Children.Add(Ui.IconButton("", L("Удалить"), async () =>
            {
                if (await Ui.Confirm(XamlRoot, L("Удалить %@?", s.Name), L("Раскладка будет удалена, хосты и сессии не затрагиваются."), L("Удалить")))
                {
                    SavedLayouts.Remove(s.Id);
                    Build();
                }
            }));
            var description = string.Join(" · ", hosts) + (missing.Count > 0 ? "\n" + L("Нет в конфиге: %@", string.Join(", ", missing)) : "");
            body.Children.Add(Ui.Row("", s.Name, description, actions));
        }
    }

    private static System.Collections.Generic.List<string> Hosts(string layout)
    {
        var hosts = new System.Collections.Generic.List<string>();
        SavedLayouts.MapLeaves(System.Text.Json.Nodes.JsonNode.Parse(layout), a => { hosts.Add(a); return a; });
        return hosts;
    }

    private async Task Rename(SavedLayouts.Saved s)
    {
        var name = new TextBox { Header = L("Название"), Text = s.Name };
        var dialog = new ContentDialog
        {
            Title = L("Переименовать"),
            Content = name,
            PrimaryButtonText = L("Сохранить"),
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || name.Text.Trim().Length == 0) return;
        SavedLayouts.Rename(s.Id, name.Text.Trim());
        Build();
    }
}
