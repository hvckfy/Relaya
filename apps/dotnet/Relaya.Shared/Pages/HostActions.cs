using System;
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
        // Файлы хоста как диск (6.7), как «Открыть в Finder» на Mac: WebDAV-мост на 127.0.0.1.
        if (Platform.DavBridge.Supported)
            menu.Items.Add(Platform.DavBridge.IsMounted(h.alias)
                ? Item(L("Отключить диск"), "\uEDA2", () => _ = DiskAsync(anchor.XamlRoot, () => Platform.DavBridge.UnmountAsync(h.alias)))
                : Item(L("Подключить как диск…"), "\uEDA2", () => _ = MountDiskAsync(anchor.XamlRoot, h.alias)));
        // tmux control mode (4.17): окна сессии tmux хоста — вкладками Relaya, как на Mac.
        menu.Items.Add(Item(L("Окна tmux как вкладки"), "\uE8A1", () => _ = Terminal.TmuxControlClient.OpenAsync(h.alias, anchor.XamlRoot)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L("Изменить…"), "", async () => await HostEditor.Show(anchor.XamlRoot, h, false)));
        menu.Items.Add(Item(L("Настроить вход по ключу…"), "\uE8D7", () => MainWindow.Current?.ShowPage(new KeyWizardPage(h))));
        menu.Items.Add(Item(L("Дублировать"), "", async () => await HostEditor.Show(anchor.XamlRoot, h, true)));
        var groups = new MenuFlyoutSubItem { Text = L("Переместить в группу"), Icon = new FontIcon { Glyph = "" } };
        groups.Items.Add(GroupItem(h, null, L("Без группы")));
        foreach (var g in AppState.Groups()) groups.Items.Add(GroupItem(h, g, g));
        // Новая группа прямо из меню (1.6): имя — и хост сразу в ней.
        groups.Items.Add(new MenuFlyoutSeparator());
        var newGroup = new MenuFlyoutItem { Text = L("Новая группа…") };
        newGroup.Click += async (_, _) =>
        {
            var name = new TextBox { Header = L("Название группы") };
            var d = new ContentDialog
            {
                Title = L("Новая группа"), Content = name, PrimaryButtonText = L("Создать"), CloseButtonText = L("Отмена"),
                DefaultButton = ContentDialogButton.Primary, XamlRoot = anchor.XamlRoot,
            };
            if (await d.ShowAsync() != ContentDialogResult.Primary || name.Text.Trim().Length == 0) return;
            try { AppState.SetMeta(h with { group = name.Text.Trim() }); }
            catch (Exception e) { await Ui.ShowError(anchor.XamlRoot, L("Не удалось сохранить"), e.Message); }
        };
        groups.Items.Add(newGroup);
        menu.Items.Add(groups);
        menu.Items.Add(Item(L("Пароль…"), "\ue8d7", async () => await HostEditor.AskPassword(anchor.XamlRoot, h.alias)));
        if (Platform.CredentialStore.Has(h.alias))
            menu.Items.Add(Item(L("Забыть пароль"), "\ue8d8", () => Platform.CredentialStore.Delete(h.alias)));
        // Вход по паролю на сервере (1.12, как на Mac): команда sshd под ОС хоста — ядро; вставляется в терминал
        // с подтверждением, без sudo под root. ОС не определена — считаем Linux.
        var sshd = new MenuFlyoutSubItem { Text = L("Вход по паролю на сервере"), Icon = new FontIcon { Glyph = "\uE72E" } };
        foreach (var (title, enabled) in new[] { (L("Разрешить…"), true), (L("Запретить…"), false) })
        {
            var item = new MenuFlyoutItem { Text = title };
            item.Click += async (_, _) =>
            {
                var cmd = RelayaCoreMethods.OsCommandForUser(
                    RelayaCoreMethods.OsPasswordLoginCommand(h.os ?? ServerOs.Linux, enabled), h.user ?? "");
                var text = enabled
                    ? L("На %@ будет разрешён вход по паролю в sshd. Команда откроется в терминале — проверьте её и нажмите Enter.", h.alias)
                    : L("На %@ будет запрещён вход по паролю в sshd. Сначала убедитесь, что вход по ключу работает, иначе можно потерять доступ.", h.alias);
                if (await Ui.Confirm(anchor.XamlRoot, enabled ? L("Разрешить вход по паролю?") : L("Запретить вход по паролю?"), text,
                        enabled ? L("Разрешить") : L("Запретить")))
                    MainWindow.Current?.OpenSession(h.alias, cmd);
            };
            sshd.Items.Add(item);
        }
        menu.Items.Add(sshd);
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
        // Только строка `# relaya:` — остальной блок хоста (комментарии, Match, порядок) не переписывается.
        i.Click += (_, _) => AppState.SetMeta(h with { group = group });
        return i;
    }

    private static async System.Threading.Tasks.Task MountDiskAsync(XamlRoot root, string alias)
    {
        var folder = new TextBox { Header = L("Папка на сервере"), Text = "~", Description = L("/ — весь сервер, ~ — домашняя папка") };
        var d = new ContentDialog
        {
            Title = L("Подключить как диск"), XamlRoot = root, Content = folder,
            PrimaryButtonText = L("Подключить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary,
        };
        if (await d.ShowAsync() != ContentDialogResult.Primary) return;
        await DiskAsync(root, () => Platform.DavBridge.MountAsync(alias, folder.Text));
    }

    private static async System.Threading.Tasks.Task DiskAsync(XamlRoot root, Func<System.Threading.Tasks.Task> action)
    {
        try { await action(); }
        catch (Exception e) { await Platform.DesktopLauncher.Message(root, e.Message); }
    }
}
