using System;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using System.Text;
using Windows.UI;
using uniffi.relaya_core;

namespace Relaya.Terminal;

/// Нативный терминал: состояние экрана — эмулятор из Rust-ядра, отрисовка — Win2D (DirectX/DirectWrite).
internal sealed class TerminalView : UserControl
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

    /// Байты от клавиатуры и вставки — в ssh.
    public event Action<byte[]>? Input;

    public TerminalView()
    {
        Content = canvas;
        canvas.Draw += OnDraw;
        SizeChanged += (_, _) => FitToSize();
        Unloaded += (_, _) => canvas.RemoveFromVisualTree();
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        PointerPressed += (_, _) => Focus(FocusState.Pointer);
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
        PointerWheelChanged += OnWheel;
    }

    private void Send(string s)
    {
        Emulator.ScrollToBottom();
        Input?.Invoke(Encoding.UTF8.GetBytes(s));
    }

    // Клавиши без символа: стрелки, F-клавиши, навигация. Символы (и Ctrl+буква) приходят в CharacterReceived.
    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (ctrl && shift && e.Key == VirtualKey.V) { e.Handled = true; _ = Paste(); return; }
        var seq = e.Key switch
        {
            VirtualKey.Tab => shift ? "\x1b[Z" : "\t",
            VirtualKey.Up => "\x1b[A", VirtualKey.Down => "\x1b[B",
            VirtualKey.Right => "\x1b[C", VirtualKey.Left => "\x1b[D",
            VirtualKey.Home => "\x1b[H", VirtualKey.End => "\x1b[F",
            VirtualKey.Insert => "\x1b[2~", VirtualKey.Delete => "\x1b[3~",
            VirtualKey.PageUp => "\x1b[5~", VirtualKey.PageDown => "\x1b[6~",
            VirtualKey.F1 => "\x1bOP", VirtualKey.F2 => "\x1bOQ", VirtualKey.F3 => "\x1bOR", VirtualKey.F4 => "\x1bOS",
            VirtualKey.F5 => "\x1b[15~", VirtualKey.F6 => "\x1b[17~", VirtualKey.F7 => "\x1b[18~", VirtualKey.F8 => "\x1b[19~",
            VirtualKey.F9 => "\x1b[20~", VirtualKey.F10 => "\x1b[21~", VirtualKey.F11 => "\x1b[23~", VirtualKey.F12 => "\x1b[24~",
            _ => null,
        };
        if (seq == null) return;
        e.Handled = true;
        Send(seq);
    }

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        e.Handled = true;
        var ch = e.Character;
        if (ch == '\t') return; // уже отправлен в KeyDown
        Send(ch == '\b' ? "\x7f" : ch.ToString());
    }

    private async System.Threading.Tasks.Task Paste()
    {
        var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
        if (!content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) return;
        var text = (await content.GetTextAsync()).Replace("\r\n", "\r").Replace('\n', '\r');
        Send(Emulator.Snapshot().bracketedPaste ? $"\x1b[200~{text}\x1b[201~" : text);
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var delta = e.GetCurrentPoint(this).Properties.MouseWheelDelta;
        Emulator.Scroll(delta / 40);
        canvas.Invalidate();
        e.Handled = true;
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
