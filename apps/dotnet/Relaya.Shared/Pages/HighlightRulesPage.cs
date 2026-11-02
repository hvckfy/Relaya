using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Terminal;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Правила подсветки вывода (4.8, как «Подсветка» в настройках Mac): включить, имя, шаблон, регулярка или текст,
/// регистр, цвет ANSI, жирный; добавить, удалить, сбросить к стандартным. Порядок — сверху вниз, первое совпадение важнее.
internal sealed class HighlightRulesPage : UserControl
{
    private List<HighlightRule> rules = HighlightRules.Load();

    public HighlightRulesPage() => Build();

    private void Build()
    {
        var (page, body) = Ui.Scaffold(L("Правила подсветки"),
            Ui.Button(L("Добавить правило"), () =>
            {
                rules.Add(new HighlightRule(L("Новое правило"), "", false, false, 11, false, true));
                Save();
            }, accent: true));
        Content = page;
        body.Children.Add(Ui.Secondary(L("Правила — сверху вниз, первое совпадение важнее. Цвета берутся из темы терминала.")));
        for (var i = 0; i < rules.Count; i++) body.Children.Add(RuleCard(i));
        body.Children.Add(Ui.Button(L("Сбросить к стандартным"), async () =>
        {
            if (!await Ui.Confirm(XamlRoot, L("Сбросить правила подсветки?"), L("Свои правила будут удалены, вернутся стандартные."), L("Сбросить"))) return;
            HighlightRules.Reset();
            rules = HighlightRules.Load();
            Build();
        }));
    }

    private UIElement RuleCard(int index)
    {
        var r = rules[index];
        var enabled = new CheckBox { IsChecked = r.Enabled, Content = L("Включено") };
        var name = new TextBox { Header = L("Название"), Text = r.Name, MinWidth = 200 };
        var pattern = new TextBox
        {
            Header = L("Текст или регулярное выражение"),
            Text = r.Pattern,
            MinWidth = 320,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas, monospace")
        };
        var regex = new CheckBox { IsChecked = r.IsRegex, Content = L("Регулярное выражение") };
        var caseSensitive = new CheckBox { IsChecked = r.CaseSensitive, Content = L("Учитывать регистр") };
        var bold = new CheckBox { IsChecked = r.Bold, Content = L("Жирный") };
        var color = new ComboBox { Header = L("Цвет"), MinWidth = 180 };
        foreach (var c in HighlightRules.ColorNames) color.Items.Add(L(c));
        color.SelectedIndex = System.Math.Clamp(r.Color, 0, 15);
        var error = new TextBlock { Foreground = Ui.Brush("SystemFillColorCriticalBrush"), TextWrapping = TextWrapping.Wrap };

        void Commit()
        {
            var updated = r with
            {
                Enabled = enabled.IsChecked == true,
                Name = name.Text.Trim(),
                Pattern = pattern.Text,
                IsRegex = regex.IsChecked == true,
                CaseSensitive = caseSensitive.IsChecked == true,
                Bold = bold.IsChecked == true,
                Color = System.Math.Max(0, color.SelectedIndex),
            };
            error.Text = updated.IsRegex && updated.Pattern.Length > 0 && HighlightRules.Compile(new[] { updated with { Enabled = true } }).Count == 0
                ? L("Неверное регулярное выражение — правило не применяется.") : "";
            rules[index] = r = updated;
            HighlightRules.Save(rules);
        }
        foreach (var cb in new[] { enabled, regex, caseSensitive, bold }) cb.Click += (_, _) => Commit();
        name.LostFocus += (_, _) => Commit();
        pattern.LostFocus += (_, _) => Commit();
        color.SelectionChanged += (_, _) => Commit();

        var remove = Ui.Button(L("Удалить…"), async () =>
        {
            if (!await Ui.Confirm(XamlRoot, L("Удалить правило «%@»?", r.Name), L("Подсветка по нему пропадёт."), L("Удалить"))) return;
            rules.RemoveAt(index);
            Save();
        });
        return Ui.Card(new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { enabled, name, color } },
                pattern,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { regex, caseSensitive, bold, remove } },
                error,
            },
        });
    }

    private void Save()
    {
        HighlightRules.Save(rules);
        Build();
    }
}
