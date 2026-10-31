//! Запустит ли ssh для хоста программы из конфига (ProxyCommand, LocalCommand, KnownHostsCommand, Match exec).
//! Такие программы — потомки нашего ssh и наследуют сокет askpass: клиенты не выдают им сохранённый пароль.
//! Разбор статический: `ssh -G` не подходит — он сам выполняет `Match exec`.

use crate::ssh_config::split_key_value;
use std::path::{Path, PathBuf};

const MAX_DEPTH: u32 = 5;
const RISKY: &[&str] = &["proxycommand", "localcommand", "knownhostscommand", "proxyusefdpass", "permitlocalcommand"];

/// Домашняя `.ssh`: HOME, на Windows — USERPROFILE.
fn default_ssh_dir() -> PathBuf {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).unwrap_or_default();
    PathBuf::from(home).join(".ssh")
}

/// Строки конфига с раскрытыми Include (пути относительно `.ssh`, `~/` — от домашнего каталога, glob по алфавиту).
fn expand(text: &str, ssh_dir: &Path, depth: u32, out: &mut Vec<String>) {
    for raw in text.split(['\n', '\r']) {
        let (key, value) = split_key_value(raw.trim());
        if key != "include" || raw.trim_start().starts_with('#') { out.push(raw.to_string()); continue; }
        if depth >= MAX_DEPTH { continue; }
        for p in value.split_whitespace().map(|p| p.trim_matches('"')) {
            let full = if let Some(rest) = p.strip_prefix("~/") {
                ssh_dir.parent().unwrap_or(ssh_dir).join(rest)
            } else if Path::new(p).is_absolute() { PathBuf::from(p) } else { ssh_dir.join(p) };
            let mut files: Vec<PathBuf> = glob::glob(&full.to_string_lossy()).map(|g| g.flatten().collect()).unwrap_or_default();
            files.sort();
            for f in files {
                if let Ok(t) = std::fs::read_to_string(&f) { expand(&t, ssh_dir, depth + 1, out); }
            }
        }
    }
}

/// `*` и `?` как в ssh_config, без учёта регистра.
fn wildcard(pattern: &str, name: &str) -> bool {
    glob::Pattern::new(&pattern.to_lowercase().replace('[', "[[]")).map(|g| g.matches(&name.to_lowercase())).unwrap_or(false)
}

/// `Host a *.lan !db.lan`: хоть один положительный шаблон совпал и ни один `!` не совпал.
fn host_matches(patterns: &str, alias: &str) -> bool {
    let mut hit = false;
    for p in patterns.split_whitespace() {
        if let Some(neg) = p.strip_prefix('!') { if wildcard(neg, alias) { return false; } }
        else if wildcard(p, alias) { hit = true; }
    }
    hit
}

/// Истина, если ssh для `alias` может запустить программу из конфига: ProxyCommand (кроме none), LocalCommand при
/// PermitLocalCommand yes, KnownHostsCommand, ProxyUseFdpass; консервативно — любой `Match … exec` и любой блок Match
/// с такими директивами. Include из `ssh_dir` раскрываются (глубина до 5), первое значение директивы побеждает.
#[uniffi::export]
pub fn config_runs_commands_in(text: String, alias: String, ssh_dir: String) -> bool {
    let mut lines = Vec::new();
    expand(&text, Path::new(&ssh_dir), 0, &mut lines);
    let mut applies = true;
    let mut in_match = false;
    let mut first: std::collections::HashMap<String, String> = Default::default();
    for raw in &lines {
        let t = raw.trim();
        if t.is_empty() || t.starts_with('#') { continue; }
        let (key, value) = split_key_value(t);
        match key.as_str() {
            "host" => { in_match = false; applies = host_matches(&value, &alias); }
            "match" => {
                in_match = true;
                if value.split_whitespace().any(|w| w.eq_ignore_ascii_case("exec")) { return true; }
            }
            k if RISKY.contains(&k) => {
                if in_match { return true; }
                if applies { first.entry(key.clone()).or_insert(value); }
            }
            _ => {}
        }
    }
    let on = |k: &str| first.get(k).map(|v| !v.eq_ignore_ascii_case("none") && !v.trim().is_empty()).unwrap_or(false);
    let yes = |k: &str| first.get(k).map(|v| v.eq_ignore_ascii_case("yes")).unwrap_or(false);
    on("proxycommand") || on("knownhostscommand") || yes("proxyusefdpass") || (on("localcommand") && yes("permitlocalcommand"))
}

/// То же для домашней `~/.ssh` (HOME, на Windows USERPROFILE).
#[uniffi::export]
pub fn config_runs_commands(text: String, alias: String) -> bool {
    config_runs_commands_in(text, alias, default_ssh_dir().to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runs(text: &str, alias: &str) -> bool { config_runs_commands_in(text.into(), alias.into(), "/nonexistent/.ssh".into()) }

    #[test]
    fn direct_wildcard_and_order() {
        assert!(runs("Host web\n    ProxyCommand nc %h %p\n", "web"));
        assert!(!runs("Host web\n    ProxyCommand nc %h %p\n", "db"));
        assert!(runs("Host db\n    User x\n\nHost *\n    ProxyCommand evil\n", "db"));
        assert!(runs("Host *.lan !nas.lan\n    ProxyCommand evil\n", "web.LAN"));
        assert!(!runs("Host *.lan !nas.lan\n    ProxyCommand evil\n", "nas.lan"));
        assert!(runs("Host w?b\n    KnownHostsCommand /x\n", "wab"));
        // Первое значение побеждает: `none` раньше `Host *`.
        assert!(!runs("Host web\n    ProxyCommand none\n\nHost *\n    ProxyCommand evil\n", "web"));
        assert!(runs("ProxyCommand evil\nHost web\n    ProxyCommand none\n", "web"));
        assert!(runs("Host web\n    ProxyUseFdpass yes\n", "web"));
        assert!(!runs("Host web\n    # ProxyCommand evil\n    HostName x\n", "web"));
    }

    #[test]
    fn local_command_needs_permit() {
        assert!(!runs("Host web\n    LocalCommand touch x\n", "web"));
        assert!(runs("Host web\n    LocalCommand touch x\n    PermitLocalCommand yes\n", "web"));
        assert!(!runs("Host web\n    PermitLocalCommand no\n    LocalCommand x\n\nHost *\n    PermitLocalCommand yes\n", "web"));
    }

    #[test]
    fn match_is_conservative() {
        assert!(runs("Host web\n    User x\n\nMatch exec \"true\"\n    User y\n", "web"));
        assert!(runs("Match host other\n    ProxyCommand evil\n", "web"));
        assert!(!runs("Match host other\n    User y\n", "web"));
    }

    #[test]
    fn follows_include() {
        let dir = tempfile::tempdir().unwrap();
        let ssh = dir.path().join(".ssh");
        std::fs::create_dir_all(ssh.join("config.d")).unwrap();
        std::fs::write(ssh.join("config.d/10-evil.conf"), "Host *\n    ProxyCommand evil\n").unwrap();
        std::fs::write(ssh.join("deep.conf"), "Include deep.conf\n").unwrap();
        let s = ssh.to_string_lossy().to_string();
        assert!(config_runs_commands_in("Include config.d/*.conf\nHost web\n    User x\n".into(), "web".into(), s.clone()));
        assert!(config_runs_commands_in("Include ~/.ssh/config.d/*\n".into(), "web".into(), s.clone()));
        assert!(!config_runs_commands_in("Include missing/*\nHost web\n    User x\n".into(), "web".into(), s.clone()));
        // Цикл Include обрывается на глубине 5.
        assert!(!config_runs_commands_in("Include deep.conf\n".into(), "web".into(), s));
    }
}
