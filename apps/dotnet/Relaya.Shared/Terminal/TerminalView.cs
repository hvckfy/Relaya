using System;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using System.Text;
using Windows.UI;
using uniffi.relaya_core;

namespace Relaya.Terminal;

/// Нативный терминал: состояние экрана — эмулятор из Rust-ядра. Здесь ввод, мышь, выделение и раскладка кадра;
/// холст и рисование — в приложении: Win2D на Windows (TerminalView.Win2D.cs), SkiaSharp на Linux (TerminalView.Skia.cs).
internal sealed partial class TerminalView : UserControl, IDisposable
{
    private double cellW = 8, cellH = 17;
    private string fontFamily = DefaultFont;
    private float fontSize = 14;
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

    // Canvas живёт, пока жива вкладка: Unloaded приходит и при смене вкладки, и при перестройке плиток.
    public void Dispose()
    {
        Platform.Settings.Changed -= OnSettingsChanged;
        RemoveCanvas();
    }

    // --- Холст: реализует приложение. ---
    /// Создать холст, поставить его в Content и подписаться на его отрисовку (она зовёт Render).
    private partial void CreateCanvas();
    private partial void RemoveCanvas();
    private partial void InvalidateCanvas();
    /// Размер ячейки для fontFamily/fontSize: ширина «M» и высота строки.
    private partial (double Width, double Height) MeasureCell();
    /// Нажата ли клавиша-модификатор сейчас.
    private static partial bool IsDown(VirtualKey key);

    /// Примитивы кадра; координаты в DIP от левого верхнего угла холста.
    internal interface IPainter
    {
        void Clear(Color color);
        void Fill(double x, double y, double w, double h, Color color);
        void Text(string text, double x, double y, Color color, bool bold, bool italic);
        void Line(double x1, double y1, double x2, double y2, Color color);
    }

    // UI-очередь снимается в конструкторе (UI-поток): Feed приходит из фонового потока ConPTY/pty.
    private readonly Microsoft.UI.Dispatching.DispatcherQueue ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly object feedLock = new();

    // Диагностика пустого экрана: %APPDATA%\Relaya\terminal.log — сбои Feed/OnDraw больше не немые.
    // Только факты и размеры (содержимое терминала — лишь в selftest-сборке); размер — настройка logs.maxKB.
    internal static void Trace(string message) =>
        Platform.LogFiles.Append(System.IO.Path.Combine(Data.AppState.Support, "terminal.log"), $"{DateTime.Now:O} {message}\n");

    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() => new TerminalAutomationPeer(this);

    // Narrator: раз в 500 мс объявляет, что вывод изменился (live region), а не на каждый кусок байт.
    private long lastAnnounce;

    private void Announce()
    {
        var now = System.Environment.TickCount64;
        if (now - lastAnnounce < 500) return;
        lastAnnounce = now;
        ui.TryEnqueue(() =>
        {
            if (Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(this) is { } peer)
                peer.RaiseAutomationEvent(Microsoft.UI.Xaml.Automation.Peers.AutomationEvents.LiveRegionChanged);
        });
    }

    private void Redraw()
    {
        if (ui == null) { Trace("Feed: no UI DispatcherQueue"); return; }
        if (!ui.TryEnqueue(InvalidateCanvas)) Trace("Feed: TryEnqueue returned false");
    }

    public TerminalView()
    {
        ApplySettings();
        // Вкладку создают свёрнутой и потом показывают: перерисовать, как только она загружена и видима.
        Loaded += (_, _) => { Trace($"Loaded {ActualWidth}x{ActualHeight}"); InvalidateCanvas(); };
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => InvalidateCanvas());
        Platform.Settings.Changed += OnSettingsChanged;
        CreateCanvas();
        SizeChanged += (_, _) => FitToSize();
        IsTabStop = true;
        // Фокус показывает системная рамка (UI-W2): своей у холста нет.
        UseSystemFocusVisuals = true;
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
        PointerWheelChanged += OnWheel;
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
    }

    private void OnSettingsChanged() => ui.TryEnqueue(() =>
    {
        ApplySettings();
        measured = false;
        InvalidateCanvas();
    });

    // Тема и шрифт — общие настройки терминала (Параметры → Терминал), как на Mac.
    private void ApplySettings()
    {
        Theme = TerminalTheme.Default;
        fontFamily = Platform.Settings.Get("terminal.font", DefaultFont);
        fontSize = float.TryParse(Platform.Settings.Get("terminal.size", "14"), out var size) ? size : 14;
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
            InvalidateCanvas();
            return i;
        }
        return -1;
    }

    public int HistoryCount => Emulator.HistoryLines().Count;

    public void ResetView()
    {
        Emulator.ScrollToBottom();
        ClearSelection();
        InvalidateCanvas();
    }

    public void ZoomFont(int delta)
    {
        var size = Math.Clamp(fontSize + delta, 8, 32);
        Platform.Settings.Set("terminal.size", size.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    private void Send(string s)
    {
        Emulator.ScrollToBottom();
        ClearSelection();
        Input?.Invoke(Encoding.UTF8.GetBytes(s));
    }

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
        InvalidateCanvas();
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
        InvalidateCanvas();
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
        InvalidateCanvas();
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
        // Окно могли уменьшить после выделения: зажимаем по границам текущего снимка.
        int rows = (int)s.rows, cols = (int)s.cols;
        if (rows == 0 || cols == 0 || from.Row >= rows) { ClearSelection(); return; }
        if (to.Row >= rows) to = (rows - 1, cols - 1);
        var lines = new System.Collections.Generic.List<string>();
        for (var r = Math.Max(0, from.Row); r <= to.Row; r++)
        {
            var sb = new StringBuilder();
            var c0 = Math.Clamp(r == from.Row ? from.Col : 0, 0, cols - 1);
            var c1 = Math.Clamp(r == to.Row ? to.Col : cols - 1, 0, cols - 1);
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
            InvalidateCanvas();
        }
        e.Handled = true;
    }

    private bool fedOnce;

    /// Из фонового потока ConPTY: эмулятор под замком, перерисовка — через UI-очередь, снятую в конструкторе.
    public void Feed(byte[] data)
    {
        lock (feedLock) Emulator.Feed(data);
        Announce();
        if (!fedOnce) { fedOnce = true; Trace($"Feed: first {data.Length} bytes"); }
        Redraw();
    }

    private void Measure()
    {
        (cellW, cellH) = MeasureCell();
        cellH = Math.Ceiling(cellH);
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
        InvalidateCanvas();
    }

    private const double Pad = 8;

    private sealed record Rule(System.Text.RegularExpressions.Regex Pattern, int Color, bool Bold);

    // Правила по умолчанию — те же, что на Mac (TerminalHighlighter): цвета — индексы ANSI, подходят к любой теме.
    private static readonly Rule[] Rules =
    {
        new(new(@"\b(error|errors|failed|failure|fatal|panic|denied|refused|critical|exception)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase), 9, true),
        new(new(@"\b(warn|warning|warnings|deprecated)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase), 11, false),
        new(new(@"\b(ok|success|successful|succeeded|done|passed|active \(running\))\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase), 10, false),
        new(new(@"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b"), 14, false),
        new(new(@"\bhttps?://[^\s'""<>]+"), 12, false),
    };

    // Подсветка считается один раз на текст строки (П3): кадр без изменений не гоняет регулярки заново.
    private readonly System.Collections.Generic.Dictionary<string, (int Color, bool Bold)?[]?> highlightCache = new();

    private (int Color, bool Bold)?[]? Highlights(TermSnapshot s, int row)
    {
        var text = new StringBuilder((int)s.cols);
        for (var c = 0; c < s.cols; c++) text.Append(s.cells[row * (int)s.cols + c].ch is { Length: > 0 } ch ? ch[0] : ' ');
        var line = text.ToString();
        if (line.Trim().Length == 0) return null;
        if (highlightCache.TryGetValue(line, out var cached)) return cached;
        if (highlightCache.Count > 512) highlightCache.Clear();
        return highlightCache[line] = HighlightLine(line, (int)s.cols);
    }

    private static (int Color, bool Bold)?[]? HighlightLine(string line, int cols)
    {
        (int, bool)?[]? marks = null;
        foreach (var rule in Rules)
            foreach (System.Text.RegularExpressions.Match m in rule.Pattern.Matches(line))
            {
                marks ??= new (int, bool)?[cols];
                for (var i = m.Index; i < m.Index + m.Length && i < marks.Length; i++) marks[i] ??= (rule.Color, rule.Bold);
            }
        return marks;
    }

    private bool drawnText;
    private string? drawError;

    /// Для самопроверки: отрисован ли хоть один кадр с текстом и была ли ошибка отрисовки.
    internal bool DrawnText => drawnText;
    internal string? DrawError => drawError;

    // Исключение в кадре с текстом не должно навсегда оставить первый пустой кадр: в лог и на экран.
    /// Вызывается из обработчика отрисовки холста.
    private void Render(IPainter painter)
    {
        try
        {
            lock (feedLock) DrawFrame(painter);
            if (!drawnText && Emulator.ScreenText().FirstOrDefault(l => l.Trim().Length > 0) is { } first)
            {
                drawnText = true;
#if RELAYA_SELFTEST
                Trace($"OnDraw: first text «{first.Trim()}» canvas {ActualWidth}x{ActualHeight}");
#else
                Trace($"OnDraw: first text, {first.Trim().Length} chars, canvas {ActualWidth}x{ActualHeight}");
#endif
            }
        }
        catch (Exception e)
        {
            if (drawError == null) Trace("OnDraw: " + e);
            drawError = e.Message;
            try
            {
                painter.Clear(Microsoft.UI.Colors.Black);
                painter.Text("Relaya: " + e.Message, 12, 12, Microsoft.UI.Colors.IndianRed, false, false);
            }
            catch (Exception) { }
        }
    }

    private void DrawFrame(IPainter ds)
    {
        if (!measured) Measure();
        ds.Clear(Theme.Background);
        var s = Emulator.Snapshot();
        var highlight = !s.altScreen && Platform.Settings.Get("terminal.highlight", "1") == "1";
        var run = new StringBuilder();
        for (var r = 0; r < s.rows; r++)
        {
            var y = Pad + r * cellH;
            var marks = highlight ? Highlights(s, r) : null;
            // Прогон соседних ASCII-ячеек одного стиля рисуется одним DrawText (П3), а не по ячейке.
            double runX = 0; Color runFg = default; bool runBold = false, runItalic = false;
            void Flush()
            {
                if (run.Length > 0) ds.Text(run.ToString().TrimEnd(), runX, y, runFg, runBold, runItalic);
                run.Clear();
            }
            for (var c = 0; c < s.cols; c++)
            {
                var cell = s.cells[r * (int)s.cols + c];
                var inverse = (cell.flags & 8) != 0;
                // Подсветка (как на Mac) — только текста цвета по умолчанию: раскрашенное сервером не трогаем.
                if (marks?[c] is { } mark && cell.fg == 0 && !inverse) cell = cell with { fg = 0x0200_0000u | (uint)mark.Color, flags = (ushort)(cell.flags | (mark.Bold ? 1 : 0)) };
                var fg = Theme.Resolve(inverse ? cell.bg : cell.fg, !inverse, (cell.flags & 1) != 0);
                var bg = Theme.Resolve(inverse ? cell.fg : cell.bg, inverse, false);
                var x = Pad + c * cellW;
                var width = (cell.flags & 64) != 0 ? cellW * 2 : cellW;
                if (cell.bg != 0 || inverse) ds.Fill(x, y, width, cellH, bg);
                if (Selected(r, c)) ds.Fill(x, y, cellW, cellH, Theme.Selection);
                if ((cell.flags & 16) != 0) fg.A = 160;
                bool bold = (cell.flags & 1) != 0, italic = (cell.flags & 2) != 0;
                var ascii = cell.ch.Length == 1 && cell.ch[0] is >= ' ' and < (char)127 && (cell.flags & 64) == 0;
                if (ascii && run.Length > 0 && fg == runFg && bold == runBold && italic == runItalic) run.Append(cell.ch[0]);
                else
                {
                    Flush();
                    if (cell.ch.Length == 0 || cell.ch == " ") { }
                    else if (ascii) { run.Append(cell.ch[0]); runX = x; runFg = fg; runBold = bold; runItalic = italic; }
                    else ds.Text(cell.ch, x, y, fg, bold, italic);
                }
                if ((cell.flags & 4) != 0) ds.Line(x, y + cellH - 1, x + width, y + cellH - 1, fg);
                if ((cell.flags & 32) != 0) ds.Line(x, y + cellH / 2, x + width, y + cellH / 2, fg);
            }
            Flush();
        }
        if (s.cursorVisible)
        {
            var cx = Pad + s.cursorCol * cellW;
            var cy = Pad + s.cursorRow * cellH;
            ds.Fill(cx, cy, cellW, cellH, Theme.Cursor with { A = 170 });
        }
    }
}
