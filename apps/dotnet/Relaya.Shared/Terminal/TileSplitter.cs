using System;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Relaya.Terminal;

/// Разделитель плиток: полоса между соседними колонками (или строками) Grid, перетаскивание меняет их доли.
internal sealed class TileSplitter : Grid
{
    private readonly Grid owner;
    private readonly bool vertical; // полоса между колонками
    private double? start;

    public TileSplitter(Grid owner, bool betweenColumns, int _)
    {
        this.owner = owner;
        vertical = betweenColumns;
        Background = Pages.Ui.Brush("SubtleFillColorTransparentBrush");
        if (vertical) Width = 6; else Height = 6;
        ProtectedCursor = InputSystemCursor.Create(vertical ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.SizeNorthSouth);
        PointerEntered += (_, _) => Background = Pages.Ui.Brush("ControlStrongStrokeColorDefaultBrush");
        PointerExited += (_, _) => { if (start == null) Background = Pages.Ui.Brush("SubtleFillColorTransparentBrush"); };
        PointerPressed += (_, e) => { start = Pos(e); CapturePointer(e.Pointer); e.Handled = true; };
        PointerReleased += (_, e) => { start = null; ReleasePointerCapture(e.Pointer); };
        PointerMoved += OnMove;
    }

    private double Pos(PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(owner).Position;
        return vertical ? p.X : p.Y;
    }

    private void OnMove(object sender, PointerRoutedEventArgs e)
    {
        if (start is not { } s) return;
        var now = Pos(e);
        var delta = now - s;
        var index = vertical ? GetColumn(this) : GetRow(this);
        if (index < 1) return;
        const double min = 120;
        if (vertical)
        {
            if (index + 1 >= owner.ColumnDefinitions.Count) return;
            var a = owner.ColumnDefinitions[index - 1]; var b = owner.ColumnDefinitions[index + 1];
            double wa = a.ActualWidth + delta, wb = b.ActualWidth - delta;
            if (wa < min || wb < min) return;
            a.Width = new GridLength(wa, GridUnitType.Star);
            b.Width = new GridLength(wb, GridUnitType.Star);
        }
        else
        {
            if (index + 1 >= owner.RowDefinitions.Count) return;
            var a = owner.RowDefinitions[index - 1]; var b = owner.RowDefinitions[index + 1];
            double ha = a.ActualHeight + delta, hb = b.ActualHeight - delta;
            if (ha < min || hb < min) return;
            a.Height = new GridLength(ha, GridUnitType.Star);
            b.Height = new GridLength(hb, GridUnitType.Star);
        }
        start = now;
        e.Handled = true;
    }
}
