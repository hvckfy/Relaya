//! Эмулятор терминала для клиентов без своего (Windows): поток байт от ssh → экран ячеек.
//! Разбор escape-последовательностей и состояние экрана — `alacritty_terminal`; клиент только рисует снимок.

use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor};

/// Цвет ячейки: 0 — цвет по умолчанию (фон или текст темы), 0x01RRGGBB — RGB, 0x02_0000II — индекс палитры 0…255.
pub const COLOR_DEFAULT: u32 = 0;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TermCell {
    pub ch: String,
    pub fg: u32,
    pub bg: u32,
    /// Биты: 1 жирный, 2 курсив, 4 подчёркнутый, 8 инверсия, 16 тусклый, 32 зачёркнутый, 64 широкий символ, 128 хвост широкого.
    pub flags: u16,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TermSnapshot {
    pub cols: u32,
    pub rows: u32,
    pub cursor_row: u32,
    pub cursor_col: u32,
    pub cursor_visible: bool,
    /// Альтернативный экран (vim, htop): прокрутка истории недоступна.
    pub alt_screen: bool,
    /// Программа просит отчёты мыши (tmux, mc).
    pub mouse_reporting: bool,
    pub bracketed_paste: bool,
    /// Стрелки как ESC O A (vim, less) вместо ESC [ A.
    pub app_cursor: bool,
    /// Отчёты мыши в формате SGR (ESC [ < b ; x ; y M).
    pub mouse_sgr: bool,
    /// Программа хочет и движение мыши с зажатой кнопкой.
    pub mouse_drag: bool,
    pub title: Option<String>,
    /// rows × cols ячеек построчно.
    pub cells: Vec<TermCell>,
}

#[derive(Default)]
struct Listener {
    out: Mutex<Vec<u8>>,
    title: Mutex<Option<String>>,
}

#[derive(Clone)]
struct Listen(Arc<Listener>);

impl EventListener for Listen {
    fn send_event(&self, event: Event) {
        match event {
            // Ответы терминала (DA, позиция курсора) уходят обратно в ssh.
            Event::PtyWrite(s) => self.0.out.lock().unwrap().extend_from_slice(s.as_bytes()),
            Event::Title(t) => *self.0.title.lock().unwrap() = Some(t),
            Event::ResetTitle => *self.0.title.lock().unwrap() = None,
            _ => {}
        }
    }
}

struct Size { cols: usize, rows: usize }

impl Dimensions for Size {
    fn total_lines(&self) -> usize { self.rows }
    fn screen_lines(&self) -> usize { self.rows }
    fn columns(&self) -> usize { self.cols }
}

struct Inner {
    term: Term<Listen>,
    parser: Processor,
}

#[derive(uniffi::Object)]
pub struct TerminalEmulator {
    inner: Mutex<Inner>,
    listener: Arc<Listener>,
}

#[uniffi::export]
impl TerminalEmulator {
    #[uniffi::constructor]
    pub fn new(cols: u32, rows: u32, scrollback: u32) -> Arc<Self> {
        let listener = Arc::new(Listener::default());
        let config = Config { scrolling_history: scrollback as usize, ..Config::default() };
        let size = Size { cols: cols.max(1) as usize, rows: rows.max(1) as usize };
        let term = Term::new(config, &size, Listen(listener.clone()));
        Arc::new(TerminalEmulator { inner: Mutex::new(Inner { term, parser: Processor::new() }), listener })
    }

    /// Байты от ssh.
    pub fn feed(&self, data: Vec<u8>) {
        let mut g = self.inner.lock().unwrap();
        let Inner { term, parser } = &mut *g;
        parser.advance(term, &data);
    }

    /// Байты, которые терминал должен отправить в ssh (ответы на запросы).
    pub fn take_output(&self) -> Vec<u8> {
        std::mem::take(&mut *self.listener.out.lock().unwrap())
    }

    pub fn resize(&self, cols: u32, rows: u32) {
        let size = Size { cols: cols.max(1) as usize, rows: rows.max(1) as usize };
        self.inner.lock().unwrap().term.resize(size);
    }

    /// Прокрутка истории: >0 вверх, <0 вниз.
    pub fn scroll(&self, lines: i32) {
        self.inner.lock().unwrap().term.scroll_display(Scroll::Delta(lines));
    }

    pub fn scroll_to_bottom(&self) {
        self.inner.lock().unwrap().term.scroll_display(Scroll::Bottom);
    }

    /// Строки экрана как текст (без хвостовых пробелов) — для копирования и тестов.
    pub fn screen_text(&self) -> Vec<String> {
        let snap = self.snapshot();
        snap.cells.chunks(snap.cols as usize)
            .map(|row| row.iter().map(|c| c.ch.as_str()).collect::<String>().trim_end().to_string())
            .collect()
    }

    pub fn snapshot(&self) -> TermSnapshot {
        let g = self.inner.lock().unwrap();
        let term = &g.term;
        let grid = term.grid();
        let (cols, rows) = (grid.columns(), grid.screen_lines());
        let offset = grid.display_offset() as i32;
        let mut cells = Vec::with_capacity(cols * rows);
        for r in 0..rows {
            for c in 0..cols {
                let cell = &grid[Point::new(Line(r as i32 - offset), Column(c))];
                let f = cell.flags;
                let mut flags = 0u16;
                for (bit, flag) in [(1, Flags::BOLD), (2, Flags::ITALIC), (4, Flags::UNDERLINE), (8, Flags::INVERSE),
                                    (16, Flags::DIM), (32, Flags::STRIKEOUT), (64, Flags::WIDE_CHAR),
                                    (128, Flags::WIDE_CHAR_SPACER)] {
                    if f.contains(flag) { flags |= bit; }
                }
                let ch = if f.contains(Flags::WIDE_CHAR_SPACER) { String::new() } else {
                    let mut s = cell.c.to_string();
                    if let Some(extra) = cell.zerowidth() { s.extend(extra); }
                    s
                };
                cells.push(TermCell { ch, fg: encode(cell.fg), bg: encode(cell.bg), flags });
            }
        }
        let cursor = grid.cursor.point;
        let mode = *term.mode();
        TermSnapshot {
            cols: cols as u32,
            rows: rows as u32,
            cursor_row: (cursor.line.0 + offset).max(0) as u32,
            cursor_col: cursor.column.0 as u32,
            cursor_visible: mode.contains(TermMode::SHOW_CURSOR) && offset == 0,
            alt_screen: mode.contains(TermMode::ALT_SCREEN),
            mouse_reporting: mode.intersects(TermMode::MOUSE_MODE),
            bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE),
            app_cursor: mode.contains(TermMode::APP_CURSOR),
            mouse_sgr: mode.contains(TermMode::SGR_MOUSE),
            mouse_drag: mode.intersects(TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION),
            title: self.listener.title.lock().unwrap().clone(),
            cells,
        }
    }
}

fn encode(color: Color) -> u32 {
    match color {
        Color::Spec(rgb) => 0x0100_0000 | (rgb.r as u32) << 16 | (rgb.g as u32) << 8 | rgb.b as u32,
        Color::Indexed(i) => 0x0200_0000 | i as u32,
        Color::Named(n) => match n {
            NamedColor::Foreground | NamedColor::Background | NamedColor::BrightForeground
            | NamedColor::DimForeground | NamedColor::Cursor => COLOR_DEFAULT,
            n if (n as usize) < 16 => 0x0200_0000 | n as u32,
            // Тусклые варианты базовых цветов → обычные.
            n => 0x0200_0000 | ((n as u32).saturating_sub(NamedColor::DimBlack as u32) & 7),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_and_newlines() {
        let t = TerminalEmulator::new(20, 3, 100);
        t.feed(b"hello\r\nworld".to_vec());
        assert_eq!(t.screen_text(), vec!["hello", "world", ""]);
        let s = t.snapshot();
        assert_eq!((s.cursor_row, s.cursor_col), (1, 5));
    }

    #[test]
    fn colors_and_bold() {
        let t = TerminalEmulator::new(10, 1, 0);
        t.feed(b"\x1b[1;31mR\x1b[0m\x1b[38;2;1;2;3mX".to_vec());
        let s = t.snapshot();
        assert_eq!(s.cells[0].fg, 0x0200_0001);
        assert_eq!(s.cells[0].flags & 1, 1);
        assert_eq!(s.cells[1].fg, 0x0101_0203);
        assert_eq!(s.cells[2].fg, COLOR_DEFAULT);
    }

    #[test]
    fn alt_screen_and_clear() {
        let t = TerminalEmulator::new(10, 2, 10);
        t.feed(b"shell".to_vec());
        t.feed(b"\x1b[?1049h\x1b[2J\x1b[Hvim".to_vec());
        assert!(t.snapshot().alt_screen);
        assert_eq!(t.screen_text()[0], "vim");
        t.feed(b"\x1b[?1049l".to_vec());
        assert_eq!(t.screen_text()[0], "shell");
    }

    #[test]
    fn scrollback_and_resize() {
        let t = TerminalEmulator::new(10, 2, 100);
        t.feed(b"a\r\nb\r\nc".to_vec());
        assert_eq!(t.screen_text(), vec!["b", "c"]);
        t.scroll(1);
        assert_eq!(t.screen_text(), vec!["a", "b"]);
        t.scroll_to_bottom();
        t.resize(5, 4);
        assert_eq!(t.snapshot().cells.len(), 20);
    }

    #[test]
    fn modes() {
        let t = TerminalEmulator::new(10, 2, 0);
        t.feed(b"\x1b[?1h\x1b[?1000h\x1b[?1006h\x1b[?2004h".to_vec());
        let s = t.snapshot();
        assert!(s.app_cursor && s.mouse_reporting && s.mouse_sgr && s.bracketed_paste && !s.mouse_drag);
    }

    #[test]
    fn answers_device_attributes() {
        let t = TerminalEmulator::new(10, 2, 0);
        t.feed(b"\x1b[6n".to_vec());
        assert_eq!(t.take_output(), b"\x1b[1;1R".to_vec());
        assert!(t.take_output().is_empty());
    }

    #[test]
    fn wide_chars_and_title() {
        let t = TerminalEmulator::new(10, 1, 0);
        t.feed("\x1b]0;srv\x07日x".as_bytes().to_vec());
        let s = t.snapshot();
        assert_eq!(s.title.as_deref(), Some("srv"));
        assert_eq!(s.cells[0].ch, "日");
        assert_eq!(s.cells[1].flags & 128, 128);
        assert_eq!(s.cells[2].ch, "x");
    }
}
