using System;
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
/// Шрифт по умолчанию — «monospace» системы (GNOME HIG). SkiaSharp сам алиасы fontconfig не разрешает (Л1),
/// поэтому семейство выбирается явно: заданное, если оно моноширинное, иначе `fc-match monospace`, иначе список кандидатов.
/// Текст в любом случае ставится по сетке ячеек — пропорциональный шрифт не сдвигает курсор и рамки.
internal sealed partial class TerminalView
{
    private const string DefaultFont = "monospace";
    private Surface canvas = null!;
    // Модификаторы отслеживаем сами: ввод в Uno Skia приходит событиями, общего опроса клавиатуры нет.
    // Своё множество у каждого терминала: в другом окне или вкладке нажатия свои, при потере фокуса сброс.
    // IsDown статический (объявлен в Shared), поэтому читает множество терминала с фокусом ввода.
    private readonly HashSet<VirtualKey> down = new();
    private static TerminalView? focused;

    private partial void CreateCanvas()
    {
        canvas = new Surface(this);
        Content = canvas;
        AddHandler(KeyDownEvent, new KeyEventHandler((_, e) => Track(e.Key, true)), handledEventsToo: true);
        AddHandler(KeyUpEvent, new KeyEventHandler((_, e) => Track(e.Key, false)), handledEventsToo: true);
        GotFocus += (_, _) => focused = this;
        LostFocus += (_, _) =>
        {
            lock (down) down.Clear();
            if (focused == this) focused = null;
        };
    }

    private void Track(VirtualKey key, bool pressed)
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

    private static partial bool IsDown(VirtualKey key)
    {
        if (focused is not { } view) return false;
        lock (view.down) return view.down.Contains(key);
    }

    private partial void RemoveCanvas() { }

    private partial void InvalidateCanvas() => canvas.Invalidate();

    // Шрифты кэшируются (П12): поиск в fontconfig — на смену шрифта или размера, а не на каждый кадр.
    private readonly Dictionary<(bool, bool), SKFont> fonts = new();
    private (string Family, float Size) fontKey;
    private string resolvedFamily = "";

    private static readonly string[] MonoCandidates =
        { "Cascadia Mono", "DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Ubuntu Mono", "Source Code Pro", "Hack" };

    private static readonly Lazy<string> systemMonospace = new(() => ResolveFamily(DefaultFont));

    /// Моноширинное семейство системы для других экранов (отпечатки, команды): алиас «monospace» Skia сам не разрешает.
    internal static string ResolvedMonospace => systemMonospace.Value;

    // Моноширинное семейство для запрошенного: само, если моноширинное; иначе fc-match monospace; иначе первый кандидат.
    private static string ResolveFamily(string requested)
    {
        static string? Fixed(string? name)
        {
            if (string.IsNullOrWhiteSpace(name)) return null;
            using var t = SKFontManager.Default.MatchFamily(name);
            return t is { IsFixedPitch: true } ? t.FamilyName : null;
        }
        if (requested != DefaultFont && Fixed(requested) is { } chosen) return chosen;
        if (Fixed(FcMatchMonospace()) is { } system) return system;
        foreach (var c in MonoCandidates) if (Fixed(c) is { } found) return found;
        return requested;
    }

    private static string? FcMatchMonospace()
    {
        try
        {
            var info = new System.Diagnostics.ProcessStartInfo("fc-match") { UseShellExecute = false, RedirectStandardOutput = true };
            info.ArgumentList.Add("-f");
            info.ArgumentList.Add("%{family[0]}");
            info.ArgumentList.Add("monospace");
            using var p = System.Diagnostics.Process.Start(info)!;
            var name = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit(2000);
            return name.Length > 0 ? name : null;
        }
        catch (System.Exception) { return null; }
    }

    private SKFont Font(bool bold = false, bool italic = false)
    {
        if (fontKey != (fontFamily, fontSize))
        {
            foreach (var f in fonts.Values) f.Dispose();
            fonts.Clear();
            fontKey = (fontFamily, fontSize);
            resolvedFamily = ResolveFamily(fontFamily);
            Trace($"font: «{fontFamily}» → «{resolvedFamily}» {fontSize}");
        }
        if (!fonts.TryGetValue((bold, italic), out var font))
            fonts[(bold, italic)] = font = new SKFont(SKTypeface.FromFamilyName(resolvedFamily,
                bold ? SKFontStyleWeight.Bold : SKFontStyleWeight.Normal, SKFontStyleWidth.Normal,
                italic ? SKFontStyleSlant.Italic : SKFontStyleSlant.Upright), fontSize)
            { Subpixel = true };
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

        // y — верх ячейки, как у Win2D; Skia рисует от базовой линии. Прогон ставится по символу в ячейку (x + i·cellW):
        // даже если шрифт окажется пропорциональным, сетка, рамки и курсор не разъезжаются (Л1).
        public void Text(string text, double x, double y, Color color, bool bold, bool italic)
        {
            var font = view.Font(bold, italic);
            paint.Style = SKPaintStyle.Fill;
            paint.Color = C(color);
            var baseline = (float)(y - font.Metrics.Ascent);
            if (text.Length == 1 || char.IsSurrogate(text[0])) { canvas.DrawText(text, (float)x, baseline, font, paint); return; }
            // Прогон — один SKTextBlob с позицией каждого символа (П-3), без строки на символ.
            Span<SKPoint> at = text.Length <= 512 ? stackalloc SKPoint[text.Length] : new SKPoint[text.Length];
            for (var i = 0; i < text.Length; i++) at[i] = new SKPoint((float)(x + i * view.cellW), baseline);
            using var blob = SKTextBlob.CreatePositioned(text, font, at);
            if (blob != null) canvas.DrawText(blob, 0, 0, paint);
        }

        // SKCanvasElement не хранит прошлый кадр — всегда кадр целиком.
        public bool Retained => false;

        public void ClearRow(double y, double h, Color color) { }

        public void Dispose() => paint.Dispose();
    }
}
