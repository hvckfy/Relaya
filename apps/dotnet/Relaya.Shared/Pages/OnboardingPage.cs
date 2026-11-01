using System;
using System.IO;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Первый запуск (чек-лист 1.15, как OnboardingView на Mac): три шага — что Relaya делает с ~/.ssh, что нашлось,
/// какие доступы нужны. Показывается один раз; признак — onboarding.done в настройках.
internal static class OnboardingPage
{
    private const string DoneKey = "onboarding.done";

    public static async System.Threading.Tasks.Task ShowIfFirstRun(XamlRoot root)
    {
        if (Platform.Settings.Get(DoneKey, "0") == "1") return;
        var step = 0;
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            PrimaryButtonText = L("Продолжить"),
            SecondaryButtonText = L("Назад"),
            IsSecondaryButtonEnabled = false,
            // Fluent: у ContentDialog всегда есть выход без действия — «Пропустить» (и Esc).
            CloseButtonText = L("Пропустить"),
            DefaultButton = ContentDialogButton.Primary,
        };
        void Render()
        {
            dialog.Title = step switch { 0 => L("Ваши ключи живут в ~/.ssh, а не у нас"), 1 => L("Нашли в ~/.ssh"), _ => L("Как это работает") };
            dialog.Content = step switch { 0 => Welcome(), 1 => Found(), _ => HowItWorks() };
            dialog.PrimaryButtonText = step == 2 ? L("Начать работу") : step == 1 ? L("Готово") : L("Продолжить");
            dialog.IsSecondaryButtonEnabled = step > 0;
        }
        dialog.PrimaryButtonClick += (_, a) => { if (step < 2) { a.Cancel = true; step++; Render(); } };
        dialog.SecondaryButtonClick += (_, a) => { a.Cancel = true; step = Math.Max(0, step - 1); Render(); };
        Render();
        await dialog.ShowAsync();
        // Закрыли любым способом — больше не показываем, как на Mac.
        Platform.Settings.Set(DoneKey, "1");
    }

    private static StackPanel Welcome() => new()
    {
        Spacing = 8, MaxWidth = 460,
        Children =
        {
            Ui.Secondary(L("Relaya читает ваш ~/.ssh/config и ключи как есть. Любое изменение файлов или сервера мы покажем заранее и применим только после подтверждения.")),
            Bullet(L("Нет своего хранилища и облачной синхронизации")),
            Bullet(Platform.PlatformText.PasswordStored()),
            Bullet(L("Diff и бэкап перед каждой правкой config")),
        },
    };

    private static StackPanel Found()
    {
        var hosts = AppState.Hosts.Count;
        var keys = Directory.Exists(AppState.SshDir)
            ? Directory.GetFiles(AppState.SshDir, "*.pub").Count(p => File.Exists(p[..^4]))
            : 0;
        var panel = new StackPanel { Spacing = 8, MaxWidth = 460 };
        panel.Children.Add(Ui.Secondary(L("Хостов в ~/.ssh/config: %@, пар ключей: %@. Только чтение: ничего не копируется.",
            hosts.ToString(), keys.ToString())));
        if (hosts == 0) panel.Children.Add(Ui.Secondary(L("Хостов пока нет — добавьте первый кнопкой «Новый хост…» внизу панели.")));
        return panel;
    }

    private static StackPanel HowItWorks() => new()
    {
        Spacing = 10, MaxWidth = 460,
        Children =
        {
            Permission(L("Доступ к ~/.ssh"), L("Читать config и ключи, записывать изменения после вашего подтверждения. Копия config перед правкой — в config.bak.")),
            Permission(L("Пароли"), Platform.PlatformText.PasswordStored()),
            Permission(L("Системный ssh"), L("Подключения идут через системный OpenSSH — ~/.ssh/config, ssh-agent и ProxyJump работают как в терминале.")),
        },
    };

    private static TextBlock Bullet(string text) => new() { Text = "• " + text, TextWrapping = TextWrapping.Wrap };

    private static StackPanel Permission(string title, string text) => new()
    {
        Spacing = 2,
        Children =
        {
            new TextBlock { Text = title, Style = Ui.Style("BodyStrongTextBlockStyle") },
            Ui.Secondary(text),
        },
    };
}
