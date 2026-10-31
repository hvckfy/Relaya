using System;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using uniffi.relaya_core;

namespace Relaya.Terminal;

/// Нативный терминал: состояние экрана — эмулятор из Rust-ядра, отрисовка — Win2D (DirectX/DirectWrite).
public sealed class TerminalView : UserControl
{
    private readonly CanvasControl canvas = new();
    private readonly CanvasTextFormat format = new()
    {
        FontFamily = "Cascadia Mono, Consolas", FontSize = 14, WordWrapping = CanvasWordWrapping.NoWrap,
    };
    private double cellW = 8, cellH = 17;
    private bool measured;

    public TerminalEmulator Emulator { get; } = new(80, 24, 10_000);
    public TerminalTheme Theme { get; set; } = TerminalTheme.Default;

    /// Терминал сменил размер в ячейках — сессия передаёт его в ssh (ConPTY).
    public event Action<uint, uint>? Resized;

    public TerminalView()
    {
        Content = canvas;
        canvas.Draw += OnDraw;
        SizeChanged += (_, _) => FitToSize();
        Unloaded += (_, _) => canvas.RemoveFromVisualTree();
    }

    public void Feed(byte[] data)
    {
        Emulator.Feed(data);
        DispatcherQueue.TryEnqueue(canvas.Invalidate);
    }

    private void Measure(ICanvasResourceCreator device)
    {
        using var layout = new CanvasTextLayout(device, "MMMMMMMMMM", format, 1000, 100);
        cellW = layout.LayoutBounds.Width / 10;
        cellH = Math.Ceiling(layout.LayoutBounds.Height);
        measured = true;
        FitToSize();
    }

    private void FitToSize()
    {
        if (!measured || ActualWidth <= 0) return;
        var cols = (uint)Math.Max(1, Math.Floor((ActualWidth - 2 * Pad) / cellW));
        var rows = (uint)Math.Max(1, Math.Floor((ActualHeight - 2 * Pad) / cellH));
        var s = Emulator.Snapshot();
        if (s.cols == cols && s.rows == rows) return;
        Emulator.Resize(cols, rows);
        Resized?.Invoke(cols, rows);
        canvas.Invalidate();
    }

    private const double Pad = 8;

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        if (!measured) Measure(sender);
        var ds = args.DrawingSession;
        ds.Clear(Theme.Background);
        var s = Emulator.Snapshot();
        for (var r = 0; r < s.rows; r++)
        {
            var y = Pad + r * cellH;
            for (var c = 0; c < s.cols; c++)
            {
                var cell = s.cells[r * (int)s.cols + c];
                var inverse = (cell.flags & 8) != 0;
                var fg = Theme.Resolve(inverse ? cell.bg : cell.fg, !inverse, (cell.flags & 1) != 0);
                var bg = Theme.Resolve(inverse ? cell.fg : cell.bg, inverse, false);
                var x = Pad + c * cellW;
                var width = (cell.flags & 64) != 0 ? cellW * 2 : cellW;
                if (cell.bg != 0 || inverse) ds.FillRectangle((float)x, (float)y, (float)width, (float)cellH, bg);
                if (cell.ch.Length == 0 || cell.ch == " ") continue;
                if ((cell.flags & 16) != 0) fg.A = 160;
                format.FontWeight = (cell.flags & 1) != 0 ? Microsoft.UI.Text.FontWeights.Bold : Microsoft.UI.Text.FontWeights.Normal;
                format.FontStyle = (cell.flags & 2) != 0 ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal;
                ds.DrawText(cell.ch, (float)x, (float)y, fg, format);
                if ((cell.flags & 4) != 0) ds.DrawLine((float)x, (float)(y + cellH - 1), (float)(x + width), (float)(y + cellH - 1), fg);
                if ((cell.flags & 32) != 0) ds.DrawLine((float)x, (float)(y + cellH / 2), (float)(x + width), (float)(y + cellH / 2), fg);
            }
        }
        if (s.cursorVisible)
        {
            var cx = Pad + s.cursorCol * cellW;
            var cy = Pad + s.cursorRow * cellH;
            ds.FillRectangle((float)cx, (float)cy, (float)cellW, (float)cellH, Theme.Cursor with { A = 170 });
        }
    }
}
