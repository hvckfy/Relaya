//! tmux control mode (`tmux -CC`): построчные уведомления сервера и команды клиента.

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TmuxEvent {
    Output { pane: String, data: Vec<u8> },
    WindowAdd { window: String },
    WindowClose { window: String },
    WindowRenamed { window: String, name: String },
    Reply { lines: Vec<String>, error: bool },
    Exit { reason: Option<String> },
}

/// Пошаговый разбор: держит хвост строки и незавершённый ответ между вызовами.
#[derive(Default, uniffi::Object)]
pub struct TmuxParser {
    /// Хвост строки и открытый ответ: «время номер» из `%begin` и его строки.
    state: std::sync::Mutex<(Vec<u8>, Option<(String, Vec<String>)>)>,
}

#[uniffi::export]
impl TmuxParser {
    #[uniffi::constructor]
    pub fn new() -> Self { Self::default() }

    pub fn feed(&self, bytes: Vec<u8>) -> Vec<TmuxEvent> {
        let mut st = self.state.lock().unwrap();
        st.0.extend(bytes);
        let mut events = Vec::new();
        while let Some(nl) = st.0.iter().position(|&b| b == b'\n') {
            let mut line: Vec<u8> = st.0.drain(..=nl).collect();
            line.pop();
            if line.last() == Some(&b'\r') { line.pop(); }
            // DCS-заголовок `ESC P 1000 p` перед первой строкой.
            if line.first() == Some(&27) {
                if let Some(p) = line.iter().position(|&b| b == b'%') { line.drain(..p); }
            }
            if let Some(e) = parse_line(&line, &mut st.1) { events.push(e); }
        }
        events
    }
}

/// `%begin 1700000000 42 1` → `1700000000 42`: ответ закрывает только `%end`/`%error` с тем же временем и номером.
fn guard(line: &str) -> Option<String> {
    let f: Vec<&str> = line.split(' ').collect();
    (f.len() >= 3).then(|| format!("{} {}", f[1], f[2]))
}

fn parse_line(bytes: &[u8], reply: &mut Option<(String, Vec<String>)>) -> Option<TmuxEvent> {
    let line = String::from_utf8_lossy(bytes).to_string();
    if let Some((id, r)) = reply.as_mut() {
        let closes = (line.starts_with("%end ") || line.starts_with("%error ")) && guard(&line).as_deref() == Some(id.as_str());
        if closes {
            let lines = reply.take().map(|r| r.1).unwrap_or_default();
            return Some(TmuxEvent::Reply { lines, error: line.starts_with("%error") });
        }
        // В выводе команды может встретиться строка «%end …» — это данные, а не конец ответа.
        r.push(line);
        return None;
    }
    if line.starts_with("%begin ") { *reply = Some((guard(&line).unwrap_or_default(), Vec::new())); return None; }
    let parts: Vec<&str> = line.splitn(3, ' ').collect();
    match parts[0] {
        "%output" if parts.len() >= 2 => {
            let prefix = format!("%output {} ", parts[1]).len();
            Some(TmuxEvent::Output { pane: parts[1].into(), data: unescape(bytes.get(prefix..).unwrap_or(&[])) })
        }
        "%window-add" if parts.len() >= 2 => Some(TmuxEvent::WindowAdd { window: parts[1].into() }),
        "%window-close" | "%unlinked-window-close" if parts.len() >= 2 => Some(TmuxEvent::WindowClose { window: parts[1].into() }),
        "%window-renamed" if parts.len() >= 3 => Some(TmuxEvent::WindowRenamed { window: parts[1].into(), name: parts[2].into() }),
        "%exit" => Some(TmuxEvent::Exit { reason: (parts.len() > 1).then(|| parts[1..].join(" ")) }),
        _ => None,
    }
}

/// `\ooo` (восьмеричный байт) и `\\` → байты.
pub fn unescape(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'\\' {
            let d = &s[i + 1..(i + 4).min(s.len())];
            if d.len() == 3 && d.iter().all(|b| (b'0'..=b'7').contains(b)) {
                out.push(d.iter().fold(0u8, |a, b| a.wrapping_mul(8).wrapping_add(b - b'0')));
                i += 4;
                continue;
            }
            if s.get(i + 1) == Some(&b'\\') { out.push(b'\\'); i += 2; continue; }
        }
        out.push(s[i]);
        i += 1;
    }
    out
}

#[uniffi::export]
pub fn tmux_cc_send_keys(pane: String, bytes: Vec<u8>) -> String {
    format!("send-keys -t {pane} -H {}", bytes.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" "))
}
#[uniffi::export]
pub fn tmux_cc_list_windows() -> String { "list-windows -F '#{window_id} #{pane_id} #{window_name}'".into() }
#[uniffi::export]
pub fn tmux_cc_resize(window: String, cols: i64, rows: i64) -> String { format!("resize-window -t {window} -x {} -y {}", cols.max(10), rows.max(3)) }
#[uniffi::export]
pub fn tmux_cc_capture(pane: String) -> String { format!("capture-pane -p -e -J -t {pane}") }
#[uniffi::export]
pub fn tmux_cc_kill_window(window: String) -> String { format!("kill-window -t {window}") }
#[uniffi::export]
pub fn tmux_cc_attach(name: String) -> String { format!("tmux -CC attach-session -t {name}") }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TmuxWindowInfo { pub window: String, pub pane: String, pub name: String }

#[uniffi::export]
pub fn tmux_cc_parse_windows(lines: Vec<String>) -> Vec<TmuxWindowInfo> {
    lines.iter().filter_map(|l| {
        let f: Vec<&str> = l.splitn(3, ' ').collect();
        (f.len() >= 2 && f[0].starts_with('@') && f[1].starts_with('%'))
            .then(|| TmuxWindowInfo { window: f[0].into(), pane: f[1].into(), name: f.get(2).unwrap_or(&"").to_string() })
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unescape_and_events() {
        assert_eq!(unescape(br"a\033[1mb\\c\015\012"), [97, 27, 91, 49, 109, 98, 92, 99, 13, 10]);
        let p = TmuxParser::new();
        let mut e = p.feed(b"\x1bP1000p%begin 1 2 0\n@1 %1 bash\n@2 %4 htop\n%end 1 2 0\n%out".to_vec());
        e.extend(p.feed(b"put %1 hi\\015\\012\n%window-add @3\n%window-close @2\n%exit\n".to_vec()));
        assert_eq!(e, vec![
            TmuxEvent::Reply { lines: vec!["@1 %1 bash".into(), "@2 %4 htop".into()], error: false },
            TmuxEvent::Output { pane: "%1".into(), data: b"hi\r\n".to_vec() },
            TmuxEvent::WindowAdd { window: "@3".into() },
            TmuxEvent::WindowClose { window: "@2".into() },
            TmuxEvent::Exit { reason: None },
        ]);
        // Чужой `%end` внутри ответа — строка ответа; незнакомые %-строки вне ответа пропускаются.
        let q = TmuxParser::new();
        assert_eq!(q.feed(b"%begin 5 7 1\n%end 5 8 1\nline\n%end 5 7 1\n%sessions-changed\n%pane-mode-changed %1\n".to_vec()),
                   vec![TmuxEvent::Reply { lines: vec!["%end 5 8 1".into(), "line".into()], error: false }]);
        assert_eq!(q.feed(b"%begin 6 9 1\n%error 6 9 1\n".to_vec()), vec![TmuxEvent::Reply { lines: vec![], error: true }]);
        assert_eq!(tmux_cc_send_keys("%1".into(), vec![0x6c, 0x73, 0x0d]), "send-keys -t %1 -H 6c 73 0d");
        assert_eq!(tmux_cc_parse_windows(vec!["@1 %1 bash".into(), "junk".into(), "@2 %4 my editor".into()])[1].name, "my editor");
    }
}

#[uniffi::export]
pub fn tmux_cc_unescape(bytes: Vec<u8>) -> Vec<u8> { unescape(&bytes) }
