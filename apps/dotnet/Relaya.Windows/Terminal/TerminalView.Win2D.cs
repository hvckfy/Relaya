using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Windows.System;
using Windows.UI;

namespace Relaya.Terminal;

/// Холст терминала на Windows: Win2D (DirectX/DirectWrite).
internal sealed partial class TerminalView
{
    private const string DefaultFont = "Cascadia Mono";
    private readonly CanvasControl canvas = new();
    private readonly CanvasTextFormat format = new() { WordWrapping = CanvasWordWrapping.NoWrap };
    // П-4: готовые раскладки текста по (текст, жирный, курсив) — экран без изменений не перестраивает их каждый кадр.
    // Четыре формата вместо одного изменяемого; при смене шрифта кэш и форматы сбрасываются (MeasureCell).
    private readonly System.Collections.Generic.Dictionary<(string, bool, bool), CanvasTextLayout> layouts = new();
    private readonly CanvasTextFormat?[] formats = new CanvasTextFormat?[4];

    private partial void CreateCanvas()
    {
        Content = canvas;
        canvas.Draw += (sender, args) => Render(new Painter(args.DrawingSession, this));
    }

    // Canvas снимается из дерева только при закрытии вкладки (иначе Win2D теряет устройство).
    private partial void RemoveCanvas()
    {
        canvas.RemoveFromVisualTree();
        ClearLayouts();
    }

    private partial void InvalidateCanvas() => canvas.Invalidate();

    private partial (double Width, double Height) MeasureCell()
    {
        format.FontFamily = fontFamily;
        format.FontSize = fontSize;
        ClearLayouts();
        using var layout = new CanvasTextLayout((ICanvasResourceCreator?)canvas.Device ?? CanvasDevice.GetSharedDevice(),
            "MMMMMMMMMM", format, 1000, 100);
        return (layout.LayoutBounds.Width / 10, layout.LayoutBounds.Height);
    }

    private static partial bool IsDown(VirtualKey key) =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void ClearLayouts()
    {
        foreach (var l in layouts.Values) l.Dispose();
        layouts.Clear();
        for (var i = 0; i < formats.Length; i++) { formats[i]?.Dispose(); formats[i] = null; }
    }

    private CanvasTextLayout Layout(ICanvasResourceCreator device, string text, bool bold, bool italic)
    {
        if (layouts.TryGetValue((text, bold, italic), out var cached)) return cached;
        if (layouts.Count >= 4096) ClearLayouts();
        var i = (bold ? 1 : 0) | (italic ? 2 : 0);
        var f = formats[i] ??= new CanvasTextFormat
        {
            WordWrapping = CanvasWordWrapping.NoWrap, FontFamily = format.FontFamily, FontSize = format.FontSize,
            FontWeight = bold ? Microsoft.UI.Text.FontWeights.Bold : Microsoft.UI.Text.FontWeights.Normal,
            FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
        };
        return layouts[(text, bold, italic)] = new CanvasTextLayout(device, text, f, 0, 0);
    }

    private sealed class Painter(CanvasDrawingSession ds, TerminalView view) : IPainter
    {
        public void Clear(Color color) => ds.Clear(color);
        public void Fill(double x, double y, double w, double h, Color color) => ds.FillRectangle((float)x, (float)y, (float)w, (float)h, color);
        public void Line(double x1, double y1, double x2, double y2, Color color) => ds.DrawLine((float)x1, (float)y1, (float)x2, (float)y2, color);
        public void Text(string text, double x, double y, Color color, bool bold, bool italic)
        {
            ds.DrawTextLayout(view.Layout(ds, text, bold, italic), (float)x, (float)y, color);
        }
    }
}
