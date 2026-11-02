using System;
using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using static Relaya.Strings;

namespace Relaya;

/// Вкладка полосы TabStrip: иконка, заголовок и крестик, как у TabViewItem.
internal sealed class TabStripItem : ListViewItem
{
    private readonly FontIcon icon = new() { FontSize = Pages.Ui.IconMedium };
    private readonly TextBlock text = new() { TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 240, VerticalAlignment = VerticalAlignment.Center };

    public TabStripItem(string header, string glyph, object tag, Action<TabStripItem> close)
    {
        Tag = tag;
        Header = header;
        MinHeight = 32;
        MinWidth = 0;
        Padding = new Thickness(12, 0, 4, 0);
        Margin = new Thickness(0);
        CornerRadius = new CornerRadius(8, 8, 0, 0);
        var closeButton = Pages.Ui.IconButton("", L("Закрыть вкладку"), () => close(this));
        closeButton.Padding = new Thickness(4);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        icon.Glyph = glyph;
        row.Children.Add(icon);
        row.Children.Add(text);
        row.Children.Add(closeButton);
        Content = row;
        // Средняя кнопка мыши закрывает вкладку, как в TabView и браузерах.
        PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(this).Properties.IsMiddleButtonPressed) return;
            e.Handled = true;
            close(this);
        };
    }

    public string Header
    {
        get => text.Text;
        set
        {
            text.Text = value;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, value);
        }
    }

    /// Иконка вкладки; tint — цвет хоста или null (цвет текста).
    public void SetIcon(string glyph, Microsoft.UI.Xaml.Media.Brush? tint)
    {
        icon.Glyph = glyph;
        if (tint != null) icon.Foreground = tint;
        else icon.ClearValue(IconElement.ForegroundProperty);
    }

    /// Вкладка на экране: фон слоя контента, как выбранная вкладка TabView.
    public bool IsCurrent
    {
        get => isCurrent;
        set
        {
            isCurrent = value;
            Background = value ? Pages.Ui.Brush("LayerFillColorDefaultBrush") : null;
        }
    }

    private bool isCurrent;
}

/// Полоса вкладок вместо TabView (0.17.7). TabView выбирает вкладку уже на нажатии, и перетаскивание вкладки
/// в плитки с этим не уживалось. Здесь, как на Mac, нажатие ничего не выбирает: вкладка выбирается щелчком
/// (отпускание без перетаскивания), а при перетаскивании на экране остаётся текущая вкладка.
/// Порядок меняется перетаскиванием внутри полосы; лишние вкладки прокручиваются колёсиком.
internal sealed class TabStrip : UserControl
{
    private readonly ListView list;
    private TabStripItem? selected;

    public ObservableCollection<TabStripItem> TabItems { get; } = new();

    /// Смена выбранной вкладки: (была, стала).
    public event Action<TabStripItem?, TabStripItem?>? SelectionChanged;
    public event Action<TabStripItem>? TabDragStarting;
    public event Action? TabDragCompleted;

    public TabStrip()
    {
        list = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
            CanDragItems = true,
            CanReorderItems = true,
            AllowDrop = true,
            ItemsSource = TabItems,
            ItemsPanel = (ItemsPanelTemplate)XamlReader.Load(
                "<ItemsPanelTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\">" +
                "<ItemsStackPanel Orientation=\"Horizontal\" /></ItemsPanelTemplate>"),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        ScrollViewer.SetHorizontalScrollMode(list, ScrollMode.Enabled);
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Hidden);
        ScrollViewer.SetVerticalScrollMode(list, ScrollMode.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        list.ItemClick += (_, e) => SelectedItem = e.ClickedItem as TabStripItem;
        list.DragItemsStarting += (_, e) =>
        {
            if (e.Items.Count == 0 || e.Items[0] is not TabStripItem tab) { e.Cancel = true; return; }
            e.Data.SetText("relaya-tab");
            e.Data.RequestedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move;
            TabDragStarting?.Invoke(tab);
        };
        list.DragItemsCompleted += (_, _) => TabDragCompleted?.Invoke();
        // Колёсико прокручивает полосу по горизонтали, как у TabView.
        list.AddHandler(PointerWheelChangedEvent, new PointerEventHandler((_, e) =>
        {
            if (FindScroll(list) is not { } scroll) return;
            scroll.ChangeView(scroll.HorizontalOffset - e.GetCurrentPoint(list).Properties.MouseWheelDelta, null, null, true);
            e.Handled = true;
        }), true);
        Content = list;
    }

    public TabStripItem? SelectedItem
    {
        get => selected;
        set
        {
            if (value == selected) return;
            var old = selected;
            selected = value;
            foreach (var t in TabItems) t.IsCurrent = t == value;
            if (value != null) list.ScrollIntoView(value);
            SelectionChanged?.Invoke(old, value);
        }
    }

    public int SelectedIndex
    {
        get => selected == null ? -1 : TabItems.IndexOf(selected);
        set => SelectedItem = value >= 0 && value < TabItems.Count ? TabItems[value] : null;
    }

    private static ScrollViewer? FindScroll(DependencyObject root)
    {
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i);
            if (child is ScrollViewer s) return s;
            if (FindScroll(child) is { } found) return found;
        }
        return null;
    }
}
