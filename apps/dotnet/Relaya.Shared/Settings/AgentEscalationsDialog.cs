using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;
using Relaya.Platform;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Settings;

/// «Синхронизация расширяет права агентов» (S3): более мягкий режим хоста или новое allow-правило с другой машины
/// применяются только с согласия человека. По умолчанию — «Отклонить».
internal static class AgentEscalationsDialog
{
    private static bool open;

    public static async Task Show(Microsoft.UI.Xaml.XamlRoot root, List<AgentEscalation> list)
    {
        if (open) return;
        open = true;
        try
        {
            var rows = new StackPanel { Spacing = 8 };
            foreach (var e in list)
            {
                var host = e.host == "*" ? L("Все хосты") : e.host;
                var what = e.rule is { } rule ? L("Разрешить без подтверждения: %@", rule)
                    : $"{Mode(e.from)} → {Mode(e.to)}";
                rows.Children.Add(new StackPanel
                {
                    Children = { new TextBlock { Text = host, Style = Pages.Ui.Style("BodyStrongTextBlockStyle") }, Pages.Ui.Secondary(what) },
                });
            }
            var dialog = new ContentDialog
            {
                Title = L("Синхронизация расширяет права агентов"),
                Content = new StackPanel
                {
                    Spacing = 12,
                    MinWidth = 420,
                    Children =
                    {
                        new ScrollViewer { Content = rows, MaxHeight = 360 },
                        Pages.Ui.Secondary(L("Изменения пришли с другой машины. Без вашего согласия они не применяются; отклонённые больше не предлагаются.")),
                    },
                },
                PrimaryButtonText = L("Применить"),
                CloseButtonText = L("Отклонить"),
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = root,
            };
            var accept = await dialog.ShowAsync() == ContentDialogResult.Primary;
            try { SyncService.Shared.ApplyAgentEscalations(accept); }
            catch (Exception ex) { await Pages.Ui.ShowError(root, L("Не удалось применить изменения"), ex.Message); }
        }
        finally { open = false; }
    }

    // Те же названия режимов, что на странице «Агенты».
    private static string Mode(McpMode? m) => m switch
    {
        McpMode.Off => L("Нет доступа"),
        McpMode.ReadOnly => L("Только чтение"),
        McpMode.Confirm => L("С подтверждением"),
        McpMode.Trusted => L("Доверенный"),
        _ => L("По умолчанию"),
    };
}
