using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Ключи — файлы в ~/.ssh (как на Mac): список с отпечатками, создание ed25519, копирование публичного ключа,
/// установка на хост (authorized_keys) через терминал, чтобы пароль ввёл человек или askpass.
internal sealed class KeysPage : UserControl
{
    public KeysPage() => _ = Build();

    private async Task Build()
    {
        var (page, body) = Ui.Scaffold(L("Ключи"), Ui.Button(L("Новый ключ"), async () => await Create(), accent: true, glyph: ""));
        Content = page;
        var pubs = Directory.Exists(AppState.SshDir) ? Directory.GetFiles(AppState.SshDir, "*.pub").OrderBy(p => p).ToList() : new();
        if (pubs.Count == 0) body.Children.Add(Ui.Card(Ui.Secondary(L("В ~/.ssh нет ключей. Создайте ключ ed25519 — его можно установить на хосты и входить без пароля."))));
        foreach (var pub in pubs)
        {
            var name = Path.GetFileNameWithoutExtension(pub);
            var r = await AppState.Run(AppState.KeygenExe, new[] { "-lf", pub }, null, null, 10);
            var fingerprint = r.Status == 0 ? r.Stdout.Trim() : L("не удалось прочитать");
            var used = AppState.Hosts.Where(h => (h.identityFile ?? "").EndsWith(name)).Select(h => h.alias).ToList();
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            actions.Children.Add(Ui.Button(L("Копировать публичный"), () => Ui.Copy(File.ReadAllText(pub).Trim())));
            var install = new MenuFlyout();
            foreach (var h in AppState.Hosts)
            {
                var item = new MenuFlyoutItem { Text = h.alias };
                item.Click += (_, _) => Install(pub, h.alias);
                install.Items.Add(item);
            }
            actions.Children.Add(new DropDownButton { Content = L("Установить на хост"), Flyout = install });
            body.Children.Add(Ui.Row("", name,
                fingerprint + (used.Count > 0 ? "\n" + L("Используют: %@", string.Join(", ", used)) : ""), actions));
        }
    }

    // Ключ дописывается в authorized_keys без дублей; команда видна в терминале (пароль — человек или askpass).
    private static void Install(string pub, string alias)
    {
        var key = File.ReadAllText(pub).Trim().Replace("'", "");
        var command = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && " +
                      $"(grep -qxF '{key}' ~/.ssh/authorized_keys || echo '{key}' >> ~/.ssh/authorized_keys) && echo Relaya: key installed";
        MainWindow.Current?.OpenSession(alias, command + "\r");
    }

    private async Task Create()
    {
        var name = new TextBox { Header = L("Имя файла"), Text = "id_ed25519" };
        var comment = new TextBox { Header = L("Комментарий"), Text = System.Environment.UserName + "@" + System.Environment.MachineName };
        var pass = new PasswordBox { Header = L("Пароль ключа (необязательно)") };
        var error = Ui.Secondary("");
        var d = new ContentDialog
        {
            Title = L("Новый ключ ed25519"),
            Content = new StackPanel { Spacing = 10, MinWidth = 380, Children = { name, comment, pass, error } },
            PrimaryButtonText = L("Создать"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        d.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            var file = Path.Combine(AppState.SshDir, name.Text.Trim());
            if (name.Text.Trim().Length == 0 || File.Exists(file)) { error.Text = L("Файл уже есть или имя пустое."); args.Cancel = true; deferral.Complete(); return; }
            Directory.CreateDirectory(AppState.SshDir);
            var r = await AppState.Run(AppState.KeygenExe, new[] { "-t", "ed25519", "-f", file, "-C", comment.Text, "-N", pass.Password }, null, null, 20);
            if (r.Status != 0) { error.Text = r.Stderr.Trim(); args.Cancel = true; }
            deferral.Complete();
        };
        if (await d.ShowAsync() == ContentDialogResult.Primary) await Build();
    }
}
