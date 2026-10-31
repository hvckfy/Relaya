using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Контекстное меню хоста — короткое, как на Mac: подключить, файлы, изменить, дублировать, группа, копировать, удалить.
internal static class HostActions
{
    public static MenuFlyout Menu(SshHost h, FrameworkElement anchor)
    {
        var menu = new MenuFlyout();
        MenuFlyoutItem Item(string text, string glyph, System.Action action)
        {
            var i = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            i.Click += (_, _) => action();
            return i;
        }
        menu.Items.Add(Item(L("Подключить"), "", () => MainWindow.Current?.OpenSession(h.alias)));
        menu.Items.Add(Item(L("Открыть файлы (SFTP)"), "", () => MainWindow.Current?.OpenSftp(h.alias)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L("Изменить…"), "", async () => await HostEditor.Show(anchor.XamlRoot, h, false)));
        menu.Items.Add(Item(L("Дублировать"), "", async () => await HostEditor.Show(anchor.XamlRoot, h, true)));
        var groups = new MenuFlyoutSubItem { Text = L("Переместить в группу"), Icon = new FontIcon { Glyph = "" } };
        groups.Items.Add(GroupItem(h, null, L("Без группы")));
        foreach (var g in AppState.Groups()) groups.Items.Add(GroupItem(h, g, g));
        menu.Items.Add(groups);
        menu.Items.Add(Item(L("Копировать ssh-команду"), "", () => Ui.Copy(AppState.SshCommand(h))));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L("Удалить…"), "", async () =>
        {
            if (await Ui.Confirm(anchor.XamlRoot, L("Удалить %@?", h.alias), L("Блок хоста будет удалён из ~/.ssh/config (копия — config.relaya.bak)."), L("Удалить")))
                AppState.Remove(h.alias);
        }));
        return menu;
    }

    private static MenuFlyoutItem GroupItem(SshHost h, string? group, string title)
    {
        var i = new ToggleMenuFlyoutItem { Text = title, IsChecked = h.group == group };
        i.Click += (_, _) => AppState.Upsert(h with { group = group }, h.alias);
        return i;
    }
}
