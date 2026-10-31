//! Постоянные сессии tmux: имена, подключение с хуком-уборщиком, список, уборка брошенных.
//! Чтобы сессии не жили вечно: закрыли вкладку — kill-session; обрыв — сервер сам убьёт сессию через ttl.

use crate::shell_quote;

pub const PREFIX: &str = "relaya-";
pub const KEEP_SECONDS: i64 = 24 * 3600;
pub const CAP: usize = 10;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TmuxSession {
    pub name: String,
    pub attached: i64,
    /// Unix-время.
    pub created: f64,
    pub activity: f64,
    pub detached_at: Option<f64>,
    pub keep: bool,
}

/// Имя хоста в имени сессии: ASCII-буквы и цифры, остальное — одиночный `-`, без `-` по краям, чтобы `--` разделял
/// имя хоста и id. Не-ASCII или пустое имя — короткий хеш (FNV-1a), иначе `сервер` и `хост` совпали бы.
fn safe_alias(alias: &str) -> String {
    let lower = alias.to_lowercase();
    if lower.is_ascii() {
        let mut out = String::new();
        for c in lower.chars() {
            if c.is_ascii_alphanumeric() { out.push(c) } else if !out.ends_with('-') { out.push('-') }
        }
        let out = out.trim_matches('-').to_string();
        if !out.is_empty() { return out; }
    }
    let hash = alias.bytes().fold(0x811c9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x01000193));
    format!("h{hash:08x}")
}

/// `relaya-<alias>--`: у разных хостов префиксы не вкладываются друг в друга (`a` и `a-b`).
#[uniffi::export]
pub fn tmux_host_prefix(alias: String) -> String {
    format!("{PREFIX}{}--", safe_alias(&alias))
}

/// `relaya-<alias>--<8 hex id>`; сессия control mode — `relaya-<alias>--cc`.
#[uniffi::export]
pub fn tmux_session_name(alias: String, id: String) -> String {
    let hex: String = id.to_lowercase().chars().filter(|c| c.is_ascii_hexdigit()).take(8).collect();
    tmux_host_prefix(alias) + &format!("{hex:0<8}")
}

/// Сессия этого хоста: точное совпадение `relaya-<alias>--<8 hex>` или `relaya-<alias>--cc`, а не просто префикс.
#[uniffi::export]
pub fn tmux_is_host_session(alias: String, name: String) -> bool {
    let Some(rest) = name.strip_prefix(&tmux_host_prefix(alias)) else { return false };
    rest == "cc" || (rest.len() == 8 && rest.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()))
}

fn reaper_hook(name: &str, ttl: i64) -> String {
    let script = format!(
        "tmux set -t {name} @relaya_det $(date +%s); sleep {ttl}; [ -n \"$(tmux list-clients -t {name} 2>/dev/null)\" ] && exit 0; d=$(tmux show -qv -t {name} @relaya_det); [ $(( $(date +%s) - ${{d:-0}} )) -ge {} ] && tmux kill-session -t {name}",
        (ttl - 5).max(0));
    format!("run-shell -b '{script}'")
}

/// Для `ssh -t host <cmd>`: подключиться к сессии или создать её; без tmux — обычный shell.
#[uniffi::export]
pub fn tmux_attach_command(name: String, ttl_minutes: i64) -> String {
    let ttl = ttl_minutes.max(1) * 60;
    format!("if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s {name} \\; set -u -t {name} @relaya_keep \\; set-hook -t {name} client-detached {}; else exec \"${{SHELL:-sh}}\" -l; fi",
            shell_quote(&reaper_hook(&name, ttl)))
}

/// Подготовка сессии для control mode (обычным ssh, до `tmux -CC attach`).
#[uniffi::export]
pub fn tmux_prepare_control_command(name: String, ttl_minutes: i64) -> String {
    let ttl = ttl_minutes.max(1) * 60;
    format!("command -v tmux >/dev/null 2>&1 || {{ echo RELAYA_NO_TMUX; exit 0; }}; tmux has-session -t {name} 2>/dev/null || tmux new-session -d -s {name}; tmux set-option -t {name} window-size manual; tmux set-hook -t {name} client-detached {}",
            shell_quote(&reaper_hook(&name, ttl)))
}

/// «Оставить на сервере»: пометить и продлить срок до суток.
#[uniffi::export]
pub fn tmux_keep_command(name: String) -> String {
    format!("tmux set -t {name} @relaya_keep 1 \\; set-hook -t {name} client-detached {}", shell_quote(&reaper_hook(&name, KEEP_SECONDS)))
}

#[uniffi::export]
pub fn tmux_list_command() -> String {
    format!("tmux list-sessions -F '#{{session_name}}|#{{session_attached}}|#{{session_created}}|#{{session_activity}}|#{{@relaya_det}}|#{{@relaya_keep}}' 2>/dev/null | grep '^{PREFIX}'; true")
}

#[uniffi::export]
pub fn tmux_kill_command(names: Vec<String>) -> String {
    names.iter().map(|n| format!("tmux kill-session -t {} 2>/dev/null", shell_quote(n))).collect::<Vec<_>>().join("; ") + "; true"
}

#[uniffi::export]
pub fn tmux_parse(output: String) -> Vec<TmuxSession> {
    output.lines().filter_map(|line| {
        let f: Vec<&str> = line.split('|').collect();
        if f.len() < 4 || !f[0].starts_with(PREFIX) { return None; }
        Some(TmuxSession {
            name: f[0].into(), attached: f[1].parse().ok()?, created: f[2].parse().ok()?, activity: f[3].parse().ok()?,
            detached_at: f.get(4).and_then(|v| v.parse().ok()), keep: f.get(5) == Some(&"1"),
        })
    }).collect()
}

/// Что убрать: не подключённые, не открытые во вкладках и просроченные; сверх CAP — самые старые.
#[uniffi::export]
pub fn tmux_stale(sessions: Vec<TmuxSession>, alias: String, open: Vec<String>, ttl_minutes: i64, now: f64) -> Vec<String> {
    let mine: Vec<&TmuxSession> = sessions.iter().filter(|s| tmux_is_host_session(alias.clone(), s.name.clone())).collect();
    let idle: Vec<&TmuxSession> = mine.iter().copied().filter(|s| s.attached == 0 && !open.contains(&s.name)).collect();
    let mut kill: std::collections::HashSet<String> = idle.iter().filter(|s| {
        let ttl = if s.keep { KEEP_SECONDS as f64 } else { (ttl_minutes.max(1) * 60) as f64 };
        now - s.detached_at.unwrap_or(s.activity) >= ttl
    }).map(|s| s.name.clone()).collect();
    let excess = mine.len() as i64 - kill.len() as i64 - CAP as i64;
    if excess > 0 {
        let mut oldest: Vec<&TmuxSession> = idle.iter().copied().filter(|s| !kill.contains(&s.name)).collect();
        oldest.sort_by(|a, b| a.activity.partial_cmp(&b.activity).unwrap());
        kill.extend(oldest.into_iter().take(excess as usize).map(|s| s.name.clone()));
    }
    mine.iter().map(|s| s.name.clone()).filter(|n| kill.contains(n)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn s(name: &str, attached: i64, activity: f64, det: Option<f64>, keep: bool) -> TmuxSession {
        TmuxSession { name: name.into(), attached, created: 0.0, activity, detached_at: det, keep }
    }

    #[test]
    fn names_commands_parse() {
        assert_eq!(tmux_session_name("Web 1.prod".into(), "3F9A0000-0000".into()), "relaya-web-1-prod--3f9a0000");
        assert_eq!(tmux_session_name("a".into(), "3f9a-00z0-11".into()), "relaya-a--3f9a0001");
        assert_eq!(tmux_host_prefix("--a__b--".into()), "relaya-a-b--");
        let ru = tmux_host_prefix("сервер".into());
        assert!(ru.starts_with("relaya-h") && ru.len() == "relaya-h12345678--".len() && ru != tmux_host_prefix("хост".into()), "{ru}");
        assert!(tmux_host_prefix("".into()).starts_with("relaya-h"));
        assert!(tmux_is_host_session("a".into(), "relaya-a--3f9a0000".into()));
        assert!(tmux_is_host_session("a".into(), "relaya-a--cc".into()));
        assert!(!tmux_is_host_session("a".into(), "relaya-a-b--3f9a0000".into()));
        assert!(!tmux_is_host_session("a".into(), "relaya-a--3f9a0000x".into()));
        assert!(!tmux_is_host_session("a".into(), "relaya-a--notmine1".into()));
        let cmd = tmux_attach_command("relaya-a-1".into(), 60);
        assert!(cmd.contains("new-session -A -s relaya-a-1") && cmd.contains("sleep 3600") && cmd.contains("else exec"));
        let p = tmux_parse("relaya-a-1|0|100|200|150|1\nrelaya-a-2|1|100|300||\nother|0|1|1||\n".into());
        assert_eq!(p.len(), 2);
        assert!(p[0].keep && p[0].detached_at == Some(150.0));
    }

    #[test]
    fn stale_rules() {
        let now = 10_000.0;
        let old = now - 7200.0;
        let n = |tag: &str| format!("relaya-a--{tag:0>8}");
        let list = vec![s(&n("01d"), 0, old, Some(old), false), s(&n("f2e5"), 0, now - 60.0, Some(now - 60.0), false),
                        s(&n("a0"), 1, old, Some(old), false), s(&n("ab"), 0, old, Some(old), false),
                        s(&n("ee"), 0, old, Some(old), true), s("relaya-b--0000001d", 0, old, Some(old), false),
                        s("relaya-a-b--0000001d", 0, old, Some(old), false), s("relaya-a--cc", 0, old, Some(old), false)];
        assert_eq!(tmux_stale(list, "a".into(), vec![n("ab")], 60, now), [n("01d"), "relaya-a--cc".into()]);
        let many: Vec<_> = (0..12).map(|i| s(&n(&i.to_string()), 0, 9_000.0 + i as f64, Some(now), false)).collect();
        assert_eq!(tmux_stale(many, "a".into(), vec![], 60, now), [n("0"), n("1")]);
    }
}
