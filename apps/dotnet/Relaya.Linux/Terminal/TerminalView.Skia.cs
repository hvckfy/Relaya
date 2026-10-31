using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using SkiaSharp;
using Uno.WinUI.Graphics2DSK;
using Windows.Foundation;
using Windows.System;
using Windows.UI;

namespace Relaya.Terminal;

/// Холст терминала на Linux: SkiaSharp через SKCanvasElement Uno (рисует прямо в Skia-сцену окна).
/// Шрифт по умолчанию — «monospace»: fontconfig отдаёт моноширинный шрифт системы (GNOME HIG).
internal sealed partial class TerminalView
{
    private const string DefaultFont = "monospace";
    private Surface canvas = null!;
    // Модификаторы отслеживаем сами: ввод в Uno Skia приходит событиями, общего опроса клавиатуры нет.
    private static readonly HashSet<VirtualKey> down = new();

    private partial void CreateCanvas()
    {
        canvas = new Surface(this);
        Content = canvas;
        AddHandler(KeyDownEvent, new KeyEventHandler((_, e) => Track(e.Key, true)), handledEventsToo: true);
        AddHandler(KeyUpEvent, new KeyEventHandler((_, e) => Track(e.Key, false)), handledEventsToo: true);
        LostFocus += (_, _) => { lock (down) down.Clear(); };
    }

    private static void Track(VirtualKey key, bool pressed)
    {
        var k = key switch
        {
            VirtualKey.LeftControl or VirtualKey.RightControl => VirtualKey.Control,
            VirtualKey.LeftShift or VirtualKey.RightShift => VirtualKey.Shift,
            VirtualKey.LeftMenu or VirtualKey.RightMenu => VirtualKey.Menu,
            _ => key,
        };
        if (k is not (VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu)) return;
        lock (down) { if (pressed) down.Add(k); else down.Remove(k); }
    }

    private static partial bool IsDown(VirtualKey key) { lock (down) return down.Contains(key); }

    private partial void RemoveCanvas() { }

    private partial void InvalidateCanvas() => canvas.Invalidate();

    // Шрифты кэшируются (П12): поиск в fontconfig — на смену шрифта или размера, а не на каждый кадр.
    private readonly Dictionary<(bool, bool), SKFont> fonts = new();
    private (string Family, float Size) fontKey;

    private SKFont Font(bool bold = false, bool italic = false)
    {
        if (fontKey != (fontFamily, fontSize))
        {
            foreach (var f in fonts.Values) f.Dispose();
            fonts.Clear();
            fontKey = (fontFamily, fontSize);
        }
        if (!fonts.TryGetValue((bold, italic), out var font))
            fonts[(bold, italic)] = font = new SKFont(SKTypeface.FromFamilyName(fontFamily,
                bold ? SKFontStyleWeight.Bold : SKFontStyleWeight.Normal, SKFontStyleWidth.Normal,
                italic ? SKFontStyleSlant.Italic : SKFontStyleSlant.Upright), fontSize) { Subpixel = true };
        return font;
    }

    private partial (double Width, double Height) MeasureCell()
    {
        var font = Font();
        return (font.MeasureText("MMMMMMMMMM") / 10, font.Spacing);
    }

    private sealed class Surface(TerminalView view) : SKCanvasElement
    {
        protected override void RenderOverride(SKCanvas canvas, Size area)
        {
            using var painter = new Painter(canvas, view);
            view.Render(painter);
        }
    }

    private sealed class Painter(SKCanvas canvas, TerminalView view) : IPainter, System.IDisposable
    {
        private readonly SKPaint paint = new() { IsAntialias = true };

        private static SKColor C(Color c) => new(c.R, c.G, c.B, c.A);

        public void Clear(Color color) => canvas.Clear(C(color));

        public void Fill(double x, double y, double w, double h, Color color)
        {
            paint.Style = SKPaintStyle.Fill;
            paint.Color = C(color);
            canvas.DrawRect((float)x, (float)y, (float)w, (float)h, paint);
        }

        public void Line(double x1, double y1, double x2, double y2, Color color)
        {
            paint.Style = SKPaintStyle.Stroke;
            paint.StrokeWidth = 1;
            paint.Color = C(color);
            canvas.DrawLine((float)x1, (float)y1, (float)x2, (float)y2, paint);
        }

        // y — верх ячейки, как у Win2D; Skia рисует от базовой линии.
        public void Text(string text, double x, double y, Color color, bool bold, bool italic)
        {
            var font = view.Font(bold, italic);
            paint.Style = SKPaintStyle.Fill;
            paint.Color = C(color);
            canvas.DrawText(text, (float)x, (float)(y - font.Metrics.Ascent), font, paint);
        }

        public void Dispose() => paint.Dispose();
    }
}
