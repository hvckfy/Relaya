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

    private partial void CreateCanvas()
    {
        Content = canvas;
        canvas.Draw += (sender, args) => Render(new Painter(args.DrawingSession, format));
    }

    // Canvas снимается из дерева только при закрытии вкладки (иначе Win2D теряет устройство).
    private partial void RemoveCanvas() => canvas.RemoveFromVisualTree();

    private partial void InvalidateCanvas() => canvas.Invalidate();

    private partial (double Width, double Height) MeasureCell()
    {
        format.FontFamily = fontFamily;
        format.FontSize = fontSize;
        using var layout = new CanvasTextLayout((ICanvasResourceCreator?)canvas.Device ?? CanvasDevice.GetSharedDevice(),
            "MMMMMMMMMM", format, 1000, 100);
        return (layout.LayoutBounds.Width / 10, layout.LayoutBounds.Height);
    }

    private static partial bool IsDown(VirtualKey key) =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private sealed class Painter(CanvasDrawingSession ds, CanvasTextFormat format) : IPainter
    {
        public void Clear(Color color) => ds.Clear(color);
        public void Fill(double x, double y, double w, double h, Color color) => ds.FillRectangle((float)x, (float)y, (float)w, (float)h, color);
        public void Line(double x1, double y1, double x2, double y2, Color color) => ds.DrawLine((float)x1, (float)y1, (float)x2, (float)y2, color);
        public void Text(string text, double x, double y, Color color, bool bold, bool italic)
        {
            format.FontWeight = bold ? Microsoft.UI.Text.FontWeights.Bold : Microsoft.UI.Text.FontWeights.Normal;
            format.FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal;
            ds.DrawText(text, (float)x, (float)y, color, format);
        }
    }
}
