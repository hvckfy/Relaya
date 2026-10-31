using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace Relaya.Pages;

/// Общие кирпичики страниц в стиле «Параметров» Windows 11: заголовок, карточки, подписи.
internal static class Ui
{
    public static Style Style(string key) => (Style)Application.Current.Resources[key];
    public static Brush Brush(string key) => (Brush)Application.Current.Resources[key];

    /// Страница: заголовок, кнопки справа от него и прокручиваемое тело.
    public static (UserControl Page, StackPanel Body) Scaffold(string title, params UIElement[] actions)
    {
        var body = new StackPanel { Spacing = 4 };
        var header = new Grid { ColumnDefinitions = { new(), new() { Width = GridLength.Auto } }, Margin = new Thickness(0, 0, 0, 16) };
        header.Children.Add(new TextBlock { Text = title, Style = Style("TitleTextBlockStyle"), TextTrimming = TextTrimming.CharacterEllipsis });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        foreach (var a in actions) buttons.Children.Add(a);
        Grid.SetColumn(buttons, 1);
        header.Children.Add(buttons);
        var root = new StackPanel { MaxWidth = 1100, Margin = new Thickness(36, 24, 36, 36), Children = { header, body } };
        return (new UserControl { Content = new ScrollViewer { Content = root } }, body);
    }

    public static TextBlock Section(string text) =>
        new() { Text = text, Style = Style("BodyStrongTextBlockStyle"), Margin = new Thickness(0, 16, 0, 4) };

    public static TextBlock Secondary(string text) =>
        new() { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush"), Style = Style("CaptionTextBlockStyle") };

    /// Карточка-строка: иконка, заголовок с описанием и элемент справа.
    public static Border Row(string? glyph, string title, string? description, UIElement? trailing = null, Action? onClick = null)
    {
        var grid = new Grid
        {
            ColumnDefinitions = { new() { Width = GridLength.Auto }, new(), new() { Width = GridLength.Auto } },
            ColumnSpacing = 16, MinHeight = 44,
        };
        if (glyph != null) grid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 18, VerticalAlignment = VerticalAlignment.Center });
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis });
        if (!string.IsNullOrEmpty(description)) text.Children.Add(Secondary(description));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (trailing is FrameworkElement t)
        {
            t.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(t, 2);
            grid.Children.Add(t);
        }
        var card = Card(grid);
        if (onClick != null)
        {
            card.PointerPressed += (_, e) => { if (e.OriginalSource is not ButtonBase) onClick(); };
            card.PointerEntered += (_, _) => card.Background = Brush("CardBackgroundFillColorSecondaryBrush");
            card.PointerExited += (_, _) => card.Background = Brush("CardBackgroundFillColorDefaultBrush");
        }
        return card;
    }

    /// Файл списка не прочитался и отложен в .bak (C16) — предупреждение над страницей.
    public static void UnreadableBar(StackPanel body, string file)
    {
        if (!Data.AppState.Unreadable.TryGetValue(file, out var bak)) return;
        var bar = new InfoBar
        {
            Severity = InfoBarSeverity.Warning, IsOpen = true, IsClosable = true, Margin = new Thickness(0, 0, 0, 8),
            Title = Strings.L("Файл %@ не прочитан", file), Message = Strings.L("Оригинал сохранён как %@. Список начат заново.", bak),
        };
        bar.Closed += (_, _) => Data.AppState.Unreadable.TryRemove(file, out _);
        body.Children.Insert(0, bar);
    }

    public static Border Card(UIElement child) => new()
    {
        Child = child, Padding = new Thickness(16, 10, 16, 10), CornerRadius = new CornerRadius(4),
        Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"),
        BorderThickness = new Thickness(1),
    };

    public static Button Button(string text, Action onClick, bool accent = false, string? glyph = null)
    {
        object content = text;
        if (glyph != null)
            content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 8,
                Children = { new FontIcon { Glyph = glyph, FontSize = 14 }, new TextBlock { Text = text } },
            };
        var b = new Button { Content = content };
        if (accent) b.Style = Style("AccentButtonStyle");
        b.Click += (_, _) => onClick();
        return b;
    }

    public static Button IconButton(string glyph, string tip, Action onClick)
    {
        var b = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Padding = new Thickness(8), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        ToolTipService.SetToolTip(b, tip);
        b.Click += (_, _) => onClick();
        return b;
    }

    public static async System.Threading.Tasks.Task<bool> Confirm(XamlRoot root, string title, string text, string action)
    {
        var d = new ContentDialog
        {
            Title = title, Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = action, CloseButtonText = Strings.L("Отмена"), DefaultButton = ContentDialogButton.Close, XamlRoot = root,
        };
        return await d.ShowAsync() == ContentDialogResult.Primary;
    }

    public static void Copy(string text)
    {
        var p = new Windows.ApplicationModel.DataTransfer.DataPackage();
        p.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(p);
    }
}
