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
    private readonly CanvasTextFormat format = new() { WordWrapping = CanvasWordWrapping.NoWrap };
    private double cellW = 8, cellH = 17;
    private bool measured;

    public TerminalEmulator Emulator { get; } = new(80, 24, 10_000);
    public TerminalTheme Theme { get; set; } = TerminalTheme.Named("Relaya");

    /// Терминал сменил размер в ячейках — сессия передаёт его в ssh (ConPTY).
    public event Action<uint, uint>? Resized;

    /// Байты от клавиатуры и вставки — в ssh.
    public event Action<byte[]>? Input;

    // Выделение в координатах экрана (строка, столбец); конец включительно.
    private (int Row, int Col)? selStart, selEnd;
    private bool selecting;

    public TerminalView()
    {
        ApplySettings();
        Platform.Settings.Changed += OnSettingsChanged;
        Unloaded += (_, _) => Platform.Settings.Changed -= OnSettingsChanged;
        Content = canvas;
        canvas.Draw += OnDraw;
        SizeChanged += (_, _) => FitToSize();
        Unloaded += (_, _) => canvas.RemoveFromVisualTree();
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
        PointerWheelChanged += OnWheel;
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
    }

    private void OnSettingsChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        ApplySettings();
        measured = false;
        canvas.Invalidate();
    });

    // Тема и шрифт — общие настройки терминала (Параметры → Терминал), как на Mac.
    private void ApplySettings()
    {
        Theme = TerminalTheme.Default;
        format.FontFamily = Platform.Settings.Get("terminal.font", "Cascadia Mono");
        format.FontSize = float.TryParse(Platform.Settings.Get("terminal.size", "14"), out var size) ? size : 14;
    }

    /// Вставить текст (сниппет, команда ОС) как вставку из буфера — без Enter.
    public void Paste(string text)
    {
        text = text.Replace("\r\n", "\r").Replace('\n', '\r');
        Send(Emulator.Snapshot().bracketedPaste ? $"\x1b[200~{text}\x1b[201~" : text);
        Focus(FocusState.Programmatic);
    }

    /// Ввести текст как с клавиатуры (команда с \r выполнится).
    public void Type(string text) => Send(text);

    /// Найти текст в истории снизу вверх, начиная перед строкой `before`; показать и выделить. Возвращает индекс строки или -1.
    public int Find(string query, int before)
    {
        if (query.Length == 0) return -1;
        var lines = Emulator.HistoryLines();
        for (var i = Math.Min(before, lines.Count) - 1; i >= 0; i--)
        {
            var col = lines[i].IndexOf(query, StringComparison.OrdinalIgnoreCase);
            if (col < 0) continue;
            var row = (int)Emulator.RevealLine((uint)i);
            selStart = (row, col);
            selEnd = (row, col + query.Length - 1);
            canvas.Invalidate();
            return i;
        }
        return -1;
    }

    public int HistoryCount => Emulator.HistoryLines().Count;

    public void ResetView()
    {
        Emulator.ScrollToBottom();
        ClearSelection();
        canvas.Invalidate();
    }

    public void ZoomFont(int delta)
    {
        var size = Math.Clamp(format.FontSize + delta, 8, 32);
        Platform.Settings.Set("terminal.size", size.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    private void Send(string s)
    {
        Emulator.ScrollToBottom();
        ClearSelection();
        Input?.Invoke(Encoding.UTF8.GetBytes(s));
    }

    private static bool IsDown(VirtualKey key) =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    // Клавиши без символа: стрелки, F-клавиши, навигация, Alt+клавиша. Символы (и Ctrl+буква) — в CharacterReceived.
    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        bool ctrl = IsDown(VirtualKey.Control), shift = IsDown(VirtualKey.Shift), alt = IsDown(VirtualKey.Menu);
        if (ctrl && shift && e.Key == VirtualKey.V) { e.Handled = true; _ = Paste(); return; }
        if (ctrl && shift && e.Key == VirtualKey.C) { e.Handled = true; CopySelection(); return; }
        if (ctrl && e.Key is (VirtualKey)187 or VirtualKey.Add) { e.Handled = true; ZoomFont(1); return; }
        if (ctrl && e.Key is (VirtualKey)189 or VirtualKey.Subtract) { e.Handled = true; ZoomFont(-1); return; }
        // Alt+буква/цифра — Meta: ESC и символ (bash: Alt+B/F по словам).
        if (alt && !ctrl && e.Key is >= VirtualKey.A and <= VirtualKey.Z or >= VirtualKey.Number0 and <= VirtualKey.Number9)
        {
            var ch = (char)e.Key;
            e.Handled = true;
            Send("\x1b" + (shift ? ch : char.ToLowerInvariant(ch)));
            return;
        }
        var app = Emulator.Snapshot().appCursor;
        string Arrow(char c) => app ? $"\x1bO{c}" : $"\x1b[{c}";
        var seq = e.Key switch
        {
            VirtualKey.Tab => shift ? "\x1b[Z" : "\t",
            VirtualKey.Up => Arrow('A'), VirtualKey.Down => Arrow('B'),
            VirtualKey.Right => Arrow('C'), VirtualKey.Left => Arrow('D'),
            VirtualKey.Home => Arrow('H'), VirtualKey.End => Arrow('F'),
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

    // --- Мышь: выделение (или отчёты программе, если она их просит; Shift — всегда выделение). ---

    private (int Row, int Col) CellAt(PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(this).Position;
        var s = Emulator.Snapshot();
        var col = (int)Math.Clamp(Math.Floor((p.X - Pad) / cellW), 0, s.cols - 1);
        var row = (int)Math.Clamp(Math.Floor((p.Y - Pad) / cellH), 0, s.rows - 1);
        return (row, col);
    }

    private bool ReportsMouse(out TermSnapshot s)
    {
        s = Emulator.Snapshot();
        return s.mouseReporting && s.mouseSgr && !IsDown(VirtualKey.Shift);
    }

    private void Report(int button, (int Row, int Col) at, bool release) =>
        Input?.Invoke(Encoding.ASCII.GetBytes($"\x1b[<{button};{at.Col + 1};{at.Row + 1}{(release ? 'm' : 'M')}"));

    private static int ButtonCode(Microsoft.UI.Input.PointerPointProperties p) =>
        p.IsRightButtonPressed ? 2 : p.IsMiddleButtonPressed ? 1 : 0;

    private int lastButton;

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Focus(FocusState.Pointer);
        var props = e.GetCurrentPoint(this).Properties;
        var at = CellAt(e);
        if (ReportsMouse(out _))
        {
            lastButton = ButtonCode(props);
            Report(lastButton, at, false);
            CapturePointer(e.Pointer);
            e.Handled = true;
            return;
        }
        // Ctrl+клик по ссылке — открыть в браузере, как ⌘-клик на Mac.
        if (props.IsLeftButtonPressed && IsDown(VirtualKey.Control) && LinkAt(at) is { } url)
        {
            _ = Windows.System.Launcher.LaunchUriAsync(new Uri(url));
            e.Handled = true;
            return;
        }
        // Правая кнопка — как в Windows Terminal: есть выделение — копировать, нет — вставить.
        if (props.IsRightButtonPressed)
        {
            if (HasSelection) CopySelection(); else _ = Paste();
            e.Handled = true;
            return;
        }
        selStart = selEnd = at;
        selecting = true;
        CapturePointer(e.Pointer);
        canvas.Invalidate();
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (ReportsMouse(out var s))
        {
            if (s.mouseDrag && e.GetCurrentPoint(this).IsInContact) Report(lastButton + 32, CellAt(e), false);
            return;
        }
        if (!selecting) return;
        selEnd = CellAt(e);
        canvas.Invalidate();
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        ReleasePointerCapture(e.Pointer);
        if (ReportsMouse(out _)) { Report(lastButton, CellAt(e), true); return; }
        selecting = false;
        if (selStart == selEnd) ClearSelection();
    }

    private static readonly System.Text.RegularExpressions.Regex Url =
        new(@"(https?|ftp)://[^\s<>""'`]+[^\s<>""'`.,;:!?)\]]");

    private string? LinkAt((int Row, int Col) at)
    {
        var s = Emulator.Snapshot();
        var sb = new StringBuilder();
        for (var c = 0; c < s.cols; c++) sb.Append(s.cells[at.Row * (int)s.cols + c].ch is { Length: > 0 } ch ? ch[0] : ' ');
        foreach (System.Text.RegularExpressions.Match m in Url.Matches(sb.ToString()))
            if (at.Col >= m.Index && at.Col < m.Index + m.Length) return m.Value;
        return null;
    }

    private bool HasSelection => selStart is not null && selEnd is not null && selStart != selEnd;

    private void ClearSelection()
    {
        if (selStart is null) return;
        selStart = selEnd = null;
        canvas.Invalidate();
    }

    private ((int Row, int Col) From, (int Row, int Col) To) Ordered()
    {
        var (a, b) = (selStart!.Value, selEnd!.Value);
        return a.Row < b.Row || a.Row == b.Row && a.Col <= b.Col ? (a, b) : (b, a);
    }

    private bool Selected(int row, int col)
    {
        if (!HasSelection) return false;
        var (from, to) = Ordered();
        if (row < from.Row || row > to.Row) return false;
        if (row == from.Row && col < from.Col) return false;
        if (row == to.Row && col > to.Col) return false;
        return true;
    }

    private void CopySelection()
    {
        if (!HasSelection) return;
        var s = Emulator.Snapshot();
        var (from, to) = Ordered();
        var lines = new System.Collections.Generic.List<string>();
        for (var r = from.Row; r <= to.Row; r++)
        {
            var sb = new StringBuilder();
            var c0 = r == from.Row ? from.Col : 0;
            var c1 = r == to.Row ? to.Col : (int)s.cols - 1;
            for (var c = c0; c <= c1; c++) sb.Append(s.cells[r * (int)s.cols + c].ch);
            lines.Add(sb.ToString().TrimEnd());
        }
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(string.Join("\r\n", lines));
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        ClearSelection();
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var delta = e.GetCurrentPoint(this).Properties.MouseWheelDelta;
        if (ReportsMouse(out _))
        {
            Report(delta > 0 ? 64 : 65, CellAt(e), false);
        }
        else
        {
            Emulator.Scroll(delta / 40);
            canvas.Invalidate();
        }
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
                if (Selected(r, c)) ds.FillRectangle((float)x, (float)y, (float)cellW, (float)cellH, Theme.Selection);
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
