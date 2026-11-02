using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Параметры → Компоненты (Л5): каждая внешняя часть со статусом, назначением и командой установки
/// для этого дистрибутива с кнопкой «Скопировать». Для AppImage это единственное место, где видно, чего не хватает.
internal static class ComponentsPage
{
    public static UIElement Build()
    {
        var items = Platform.Components.List();
        var refresh = Ui.Button(L("Проверить снова"), () => { }, glyph: "");
        var (page, list) = Ui.Scaffold(L("Компоненты"), refresh);
        refresh.Click += (_, _) =>
        {
            if (page.Parent is ContentControl host) host.Content = Build();
        };
        var missing = items.Where(i => !i.Found).ToList();
        if (missing.Any(i => i.Required))
            list.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Warning,
                IsOpen = true,
                IsClosable = false,
                Margin = new Thickness(0, 0, 0, 8),
                Title = L("Не хватает обязательных компонентов"),
                Message = L("Без них часть Relaya не работает. Команды установки — ниже."),
            });
        else if (missing.Count == 0)
            list.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Success,
                IsOpen = true,
                IsClosable = false,
                Margin = new Thickness(0, 0, 0, 8),
                Title = L("Все компоненты на месте"),
            });
        foreach (var i in items)
        {
            var state = i.Found ? L("найдено") : i.Required ? L("не найдено — обязательно") : L("не найдено");
            UIElement? trailing = null;
            if (!i.Found && i.Install is { } command)
            {
                var copy = Ui.Button(L("Скопировать команду"), () => Ui.Copy(command), glyph: "");
                ToolTipService.SetToolTip(copy, command);
                trailing = copy;
            }
            var row = Ui.Row(i.Found ? "" : i.Required ? "" : "", i.Name,
                $"{i.Purpose}\n{state}{(i.Found || i.Install == null ? "" : " · " + i.Install)}", trailing);
            // Статус и цветом глифа (Fluent: системные цвета состояния), и текстом — для глаз и для диктора.
            if (row.Child is Grid { Children.Count: > 0 } g && g.Children[0] is FontIcon icon)
                icon.Foreground = Ui.Brush(i.Found ? "SystemFillColorSuccessBrush" : i.Required ? "SystemFillColorCriticalBrush" : "SystemFillColorCautionBrush");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, $"{i.Name}: {state}");
            list.Children.Add(row);
        }
        return page;
    }
}
