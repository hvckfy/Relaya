using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Platform;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Settings;

/// «Подтвердите удаление»: удаления, пришедшие синхронизацией с другой машины. По умолчанию — оставить все.
internal static class DeletionsDialog
{
    private static bool open;

    public static async Task Show(XamlRoot root, List<PendingDeletion> pending)
    {
        if (open) return; // следующий список придёт со следующей синхронизацией
        open = true;
        try
        {
            var boxes = new List<(CheckBox Box, PendingDeletion Item)>();
            var list = new StackPanel { Spacing = 4 };
            foreach (var p in pending)
            {
                var when = DateTimeOffset.TryParse(p.deletedAt, CultureInfo.InvariantCulture, DateTimeStyles.None, out var t)
                    ? t.LocalDateTime.ToString("g") : p.deletedAt;
                // По умолчанию ничего не отмечено: удаления из синхронизации мог подделать чужой репозиторий.
                var box = new CheckBox
                {
                    IsChecked = false,
                    Content = new StackPanel
                    {
                        Children =
                        {
                            new TextBlock { Text = $"{Kind(p.kind)}: {p.name}" },
                            Pages.Ui.Secondary(L("Удалено на %@, %@", p.machine, when)),
                        },
                    },
                };
                boxes.Add((box, p));
                list.Children.Add(box);
            }
            var selectAll = new HyperlinkButton { Content = L("Выбрать все"), Padding = new Thickness(0) };
            selectAll.Click += (_, _) => { foreach (var b in boxes) b.Box.IsChecked = true; };
            var dialog = new ContentDialog
            {
                Title = L("Подтвердите удаление"),
                Content = new StackPanel
                {
                    Spacing = 12, MinWidth = 420,
                    Children =
                    {
                        selectAll,
                        new ScrollViewer { Content = list, MaxHeight = 360 },
                        Pages.Ui.Secondary(L("Удаления пришли синхронизацией с другой машины. Перед удалением делается резервная копия.")),
                    },
                },
                PrimaryButtonText = L("Удалить отмеченные"), CloseButtonText = L("Оставить все"),
                DefaultButton = ContentDialogButton.Close, XamlRoot = root, IsPrimaryButtonEnabled = false,
            };
            // «Удалить отмеченные» доступна, только когда что-то отмечено.
            void Update() => dialog.IsPrimaryButtonEnabled = boxes.Any(b => b.Box.IsChecked == true);
            foreach (var b in boxes) { b.Box.Checked += (_, _) => Update(); b.Box.Unchecked += (_, _) => Update(); }
            var delete = await dialog.ShowAsync() == ContentDialogResult.Primary;
            var confirmed = delete
                ? boxes.Where(b => b.Box.IsChecked == true).Select(b => new DeletionKey(b.Item.kind, b.Item.key)).ToList()
                : new List<DeletionKey>();
            try { SyncService.Shared.ApplyDeletions(confirmed); }
            catch (Exception e) { await new ContentDialog { Title = L("Подтвердите удаление"), Content = e.Message, CloseButtonText = "OK", XamlRoot = root }.ShowAsync(); }
        }
        finally { open = false; }
    }

    private static string Kind(string kind) => kind switch
    {
        "host" => L("Хост"),
        "snippet" => L("Сниппет"),
        "tunnel" => L("Туннель"),
        "desktop" => L("Удалённый стол"),
        _ => kind,
    };
}
