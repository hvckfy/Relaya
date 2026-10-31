//! MCP: права агентов на хосты, правила, временный доступ, журнал и сервер JSON-RPC (`Relaya --mcp`).
//! Платформенные части (запуск ssh, окно подтверждения, хосты и политика с диска) даёт клиент через `McpBackend`.

use crate::shell_quote;
use crate::ssh_config::SshHost;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

/// Секунды между 1970 и 2001 годом: Swift `JSONEncoder` по умолчанию пишет даты от 2001-01-01.
const REFERENCE: f64 = 978_307_200.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum McpMode { Off, ReadOnly, Confirm, Trusted }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct McpGrant {
    pub mode: McpMode,
    /// Как в mcp.json: секунды от 2001-01-01.
    pub until: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct McpPolicy {
    pub enabled: bool,
    pub default_mode: McpMode,
    pub hosts: HashMap<String, McpMode>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub allow: Option<HashMap<String, Vec<String>>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub deny: Option<HashMap<String, Vec<String>>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub grants: Option<HashMap<String, McpGrant>>,
}

impl Default for McpPolicy {
    fn default() -> Self {
        McpPolicy { enabled: true, default_mode: McpMode::Confirm, hosts: HashMap::new(), allow: None, deny: None, grants: None }
    }
}

fn now_ref() -> f64 { std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64() - REFERENCE }

impl McpPolicy {
    pub fn grant(&self, alias: &str, now: f64) -> Option<&McpGrant> {
        self.grants.as_ref()?.get(alias).filter(|g| g.until > now)
    }
    pub fn mode(&self, alias: &str, now: f64) -> McpMode {
        if !self.enabled { return McpMode::Off; }
        if let Some(g) = self.grant(alias, now) { return g.mode; }
        *self.hosts.get(alias).unwrap_or(&self.default_mode)
    }
    fn patterns(map: &Option<HashMap<String, Vec<String>>>, alias: &str) -> Vec<String> {
        let m = match map { Some(m) => m, None => return vec![] };
        m.get("*").cloned().unwrap_or_default().into_iter().chain(m.get(alias).cloned().unwrap_or_default()).collect()
    }
    pub fn is_denied(&self, command: &str, alias: &str) -> bool {
        Self::patterns(&self.deny, alias).iter().any(|p| pattern_matches(command, p))
    }
    /// Цепочки команд правилом не разрешаются.
    pub fn is_allowed(&self, command: &str, alias: &str) -> bool {
        if [";", "&", "|", "`", "$(", "\n", ">", "<"].iter().any(|b| command.contains(b)) { return false; }
        Self::patterns(&self.allow, alias).iter().any(|p| pattern_matches(command, p))
    }
}

/// Шаблон как в shell: `*`, `?`, `[…]`.
pub fn pattern_matches(command: &str, pattern: &str) -> bool {
    let p = pattern.trim();
    !p.is_empty() && glob::Pattern::new(p).map(|g| g.matches(command.trim())).unwrap_or(false)
}

#[uniffi::export]
pub fn mcp_pattern_matches(command: String, pattern: String) -> bool { pattern_matches(&command, &pattern) }
#[uniffi::export]
pub fn mcp_mode(policy: McpPolicy, alias: String, now_ref_seconds: f64) -> McpMode { policy.mode(&alias, now_ref_seconds) }
#[uniffi::export]
pub fn mcp_grant(policy: McpPolicy, alias: String, now_ref_seconds: f64) -> Option<McpGrant> { policy.grant(&alias, now_ref_seconds).cloned() }
#[uniffi::export]
pub fn mcp_is_denied(policy: McpPolicy, command: String, alias: String) -> bool { policy.is_denied(&command, &alias) }
#[uniffi::export]
pub fn mcp_is_allowed(policy: McpPolicy, command: String, alias: String) -> bool { policy.is_allowed(&command, &alias) }
/// Политика, которую не удалось прочитать: агенты выключены, пока пользователь её не пересохранит.
fn closed_policy() -> McpPolicy { McpPolicy { enabled: false, default_mode: McpMode::ReadOnly, ..Default::default() } }

/// Пустой текст (файла ещё нет) — политика по умолчанию; повреждённый — закрытая (fail-closed), а не «всё с подтверждением».
#[uniffi::export]
pub fn mcp_policy_decode(json: String) -> McpPolicy {
    if json.trim().is_empty() { return McpPolicy::default(); }
    serde_json::from_str(&json).unwrap_or_else(|_| closed_policy())
}

/// Признак «политика не прочитана» для интерфейса: текст есть, но разобрать его нельзя.
#[uniffi::export]
pub fn mcp_policy_is_unreadable(json: String) -> bool {
    !json.trim().is_empty() && serde_json::from_str::<McpPolicy>(&json).is_err()
}
#[uniffi::export]
pub fn mcp_policy_encode(policy: McpPolicy) -> String { crate::models::encode_sorted(&policy) }

// MARK: - Только чтение

/// Строгий белый список «только чтения»: утилита (или пара «утилита подкоманда»), её короткие флаги буквами
/// и длинные флаги (`--name`, сравнение до `=`). Любой неизвестный флаг — запрет. Аргументы без `-` разрешены.
struct Tool { name: &'static str, short: &'static str, long: &'static [&'static str] }

const fn t(name: &'static str, short: &'static str, long: &'static [&'static str]) -> Tool { Tool { name, short, long } }

const READ_ONLY: &[Tool] = &[
    t("ls", "lahtrRS1dFiGn", &["--all", "--human-readable", "--color", "--sort", "--time-style", "--full-time", "--recursive"]),
    t("cat", "nAbevst", &["--number", "--show-all"]),
    t("head", "nc", &["--lines", "--bytes", "--quiet"]),
    t("tail", "ncfFq", &["--lines", "--bytes", "--follow", "--quiet"]),
    t("grep", "iEFvnclrRwxohHsqAB C m", &["--ignore-case", "--extended-regexp", "--fixed-strings", "--invert-match", "--line-number",
        "--count", "--files-with-matches", "--recursive", "--word-regexp", "--only-matching", "--color", "--include", "--exclude",
        "--max-count", "--context", "--after-context", "--before-context", "--no-filename", "--with-filename"]),
    t("egrep", "ivnclrwohHs", &["--color"]),
    t("zgrep", "ivnclwohHs", &[]),
    t("wc", "lwcm", &["--lines", "--words", "--bytes", "--chars"]),
    // sort: без -o/--output/-T/--compress-program — они пишут файлы.
    t("sort", "nrkthufbV", &["--numeric-sort", "--reverse", "--key", "--human-numeric-sort", "--unique", "--field-separator"]),
    // uniq: второй позиционный аргумент — файл вывода, см. `positional_limit`.
    t("uniq", "cdiu", &["--count", "--repeated", "--ignore-case", "--unique"]),
    t("cut", "dfcb", &["--delimiter", "--fields", "--characters", "--bytes"]),
    t("awk", "Fv", &[]),
    t("sed", "nEre", &["--quiet", "--regexp-extended", "--expression"]),
    t("df", "hTiPk", &["--human-readable", "--print-type", "--inodes"]),
    t("du", "hsdcax", &["--human-readable", "--summarize", "--max-depth", "--total"]),
    t("free", "hmgkbt", &["--human", "--mega", "--giga"]),
    t("uptime", "ps", &["--pretty", "--since"]),
    t("uname", "asnrvmpio", &["--all"]),
    t("whoami", "", &[]),
    t("id", "unG", &[]),
    t("ps", "aeuxfwlo", &["--sort", "--forest", "--no-headers"]),
    t("pgrep", "lafx", &["--list-name", "--full", "--exact"]),
    t("top", "bnoHc", &["--batch"]),
    t("stat", "Lcf", &["--format", "--dereference"]),
    t("file", "bLi", &["--brief", "--mime"]),
    t("which", "a", &[]),
    t("lsblk", "fapo", &["--fs", "--output"]),
    t("lscpu", "", &[]),
    t("lsof", "inPpcu", &[]),
    t("netstat", "tulnpar", &[]),
    t("ping", "cWinq", &[]),
    t("dig", "", &["+short"]),
    t("nslookup", "", &[]),
    t("journalctl", "unbfrxkpqS", &["--unit", "--lines", "--boot", "--since", "--until", "--priority", "--no-pager", "--follow",
        "--reverse", "--output", "--grep", "--catalog", "--dmesg", "--list-boots", "--disk-usage"]),
    t("echo", "neE", &[]),
    t("pwd", "LP", &[]),
    t("tree", "adfhLsD", &[]),
    t("md5sum", "bc", &["--check"]),
    t("sha256sum", "bc", &["--check"]),
    t("logread", "elf", &[]),
    t("iwinfo", "", &[]),
    t("sw_vers", "", &[]),
    t("vm_stat", "", &[]),
    t("nproc", "", &["--all"]),
    t("systemctl status", "nl", &["--no-pager", "--lines", "--full"]),
    t("systemctl list-units", "at", &["--type", "--state", "--all", "--no-pager", "--failed"]),
    t("systemctl --failed", "", &["--no-pager"]),
    t("systemctl is-active", "q", &["--quiet"]),
    t("docker ps", "aqn", &["--all", "--format", "--filter", "--no-trunc", "--last"]),
    t("docker logs", "nft", &["--tail", "--since", "--until", "--follow", "--timestamps"]),
    t("docker images", "aq", &["--all", "--format", "--filter"]),
    t("docker inspect", "f", &["--format", "--type"]),
    t("docker stats", "a", &["--no-stream", "--all", "--format", "--no-trunc"]),
    t("kubectl get", "onlAw", &["--namespace", "--output", "--selector", "--all-namespaces", "--show-labels", "--context"]),
    t("kubectl describe", "nlA", &["--namespace", "--selector", "--all-namespaces", "--context"]),
    t("kubectl logs", "nfcp", &["--namespace", "--container", "--tail", "--since", "--previous", "--follow", "--timestamps", "--context"]),
    t("git status", "sbu", &["--short", "--branch", "--porcelain"]),
    // git log/diff: без --output и --ext-diff.
    t("git log", "np", &["--oneline", "--graph", "--decorate", "--stat", "--since", "--until", "--author", "--format", "--pretty",
        "--max-count", "--all", "--no-merges", "--name-only", "--name-status"]),
    t("git diff", "U", &["--stat", "--cached", "--staged", "--name-only", "--name-status", "--no-ext-diff", "--color"]),
    t("apt list", "", &["--installed", "--upgradable"]),
    t("dpkg -l", "", &[]),
    t("rpm -qa", "", &[]),
    t("opkg list-installed", "", &[]),
    t("uci show", "", &[]),
    t("nginx -t", "", &[]),
];

/// `find`: предикаты с одним дефисом; запись и запуск (-delete, -exec, -fprint, -ok…) сюда не входят.
const FIND_PREDICATES: &[&str] = &["-name", "-iname", "-path", "-ipath", "-type", "-maxdepth", "-mindepth", "-mtime", "-mmin",
    "-atime", "-ctime", "-size", "-newer", "-user", "-group", "-perm", "-print", "-print0", "-ls", "-empty", "-not", "-o", "-a",
    "-and", "-or", "-xdev", "-follow", "-L", "-H", "-P", "-regex", "-iregex", "-links"];

/// Слова с учётом кавычек и `|` вне кавычек; `None`, если кавычка не закрыта.
fn segments(command: &str) -> Option<Vec<Vec<String>>> {
    let (mut segs, mut words, mut cur, mut quote, mut has) = (Vec::new(), Vec::new(), String::new(), None, false);
    for c in command.chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => cur.push(c),
            (None, '\'' | '"') => { quote = Some(c); has = true; }
            (None, '|') => { if has || !cur.is_empty() { words.push(std::mem::take(&mut cur)); } has = false; segs.push(std::mem::take(&mut words)); }
            (None, c) if c.is_whitespace() => { if has || !cur.is_empty() { words.push(std::mem::take(&mut cur)); } has = false; }
            (None, c) => cur.push(c),
        }
    }
    if quote.is_some() { return None; }
    if has || !cur.is_empty() { words.push(cur); }
    segs.push(words);
    Some(segs)
}

/// Скрипт sed без записи и запуска: `[адрес[,адрес]](p|d|q|=)` или `s/…/…/[gpI0-9]`.
fn sed_script_ok(script: &str) -> bool {
    let s = script.trim();
    if let Some(rest) = s.strip_prefix('s') {
        let Some(d) = rest.chars().next() else { return false };
        if d.is_alphanumeric() || d.is_whitespace() { return false; }
        let parts: Vec<&str> = rest[d.len_utf8()..].split(d).collect();
        return parts.len() == 3 && parts[2].chars().all(|c| "gpI0123456789".contains(c));
    }
    let Some(cmd) = s.chars().last() else { return false };
    if !"pdq=".contains(cmd) { return false; }
    let addr = &s[..s.len() - 1];
    addr.split(',').all(|a| a.is_empty() || a == "$" || a.chars().all(|c| c.is_ascii_digit())
        || (a.len() >= 2 && a.starts_with('/') && a.ends_with('/') && !a[1..a.len() - 1].contains('/')))
}

/// Короткие флаги со значением: всё после такого флага в том же слове — значение (`-d:`, `-F,`, `-es/a/b/`, `-k2,2n`).
const VALUE_FLAGS: &[(&str, &str)] = &[("cut", "dfcb"), ("sed", "e"), ("sort", "kt"), ("head", "nc"), ("tail", "nc"),
    ("grep", "ABCm"), ("awk", "Fv"), ("ps", "o"), ("journalctl", "unbpS"), ("du", "d"), ("ping", "cWi"), ("lsof", "p"),
    ("tree", "L"), ("top", "no"), ("stat", "cf"), ("lsblk", "o"), ("docker logs", "n"), ("kubectl get", "nol"),
    ("kubectl describe", "nl"), ("kubectl logs", "ncp"), ("git log", "n"), ("git diff", "U"), ("logread", "e")];

/// `-la`, `-rk3`, `-d:`: каждая буква — известный флаг; цифры и флаг со значением забирают остаток слова.
/// Возвращает приклеенное значение `-e` (скрипт sed), чтобы проверить и его.
fn short_flags_ok(tool: &str, flags: &str, allowed: &str) -> Option<Option<String>> {
    let values = VALUE_FLAGS.iter().find(|v| v.0 == tool).map(|v| v.1).unwrap_or("");
    let mut chars = flags.char_indices();
    let (_, first) = chars.next()?;
    if first == ' ' || !allowed.contains(first) { return None; }
    if values.contains(first) { return Some((first == 'e').then(|| flags[first.len_utf8()..].to_string()).filter(|v| !v.is_empty())); }
    let mut digits = false;
    for (i, c) in chars {
        if c.is_ascii_digit() || (digits && ",.".contains(c)) { digits = true; continue; }
        if digits || c == ' ' || !allowed.contains(c) { return None; }
        if values.contains(c) { return Some((c == 'e').then(|| flags[i + c.len_utf8()..].to_string()).filter(|v| !v.is_empty())); }
    }
    Some(None)
}

fn segment_ok(words: &[String]) -> bool {
    let Some(first) = words.first() else { return false };
    if first == "find" {
        // `-mtime -1`, `-size -10M` — значения, а не предикаты.
        let value = |w: &str| w[1..].chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false);
        return words[1..].iter().all(|w| !w.starts_with('-') || value(w) || FIND_PREDICATES.contains(&w.as_str()));
    }
    let pair = words.iter().take(2).cloned().collect::<Vec<_>>().join(" ");
    let (tool, rest) = match READ_ONLY.iter().find(|t| t.name == pair) {
        Some(t) => (t, &words[2.min(words.len())..]),
        None => match READ_ONLY.iter().find(|t| t.name == first.as_str()) { Some(t) => (t, &words[1..]), None => return false },
    };
    let mut positional = Vec::new();
    let mut scripts: Vec<String> = Vec::new();
    let mut flags_done = false;
    for w in rest {
        if flags_done || !w.starts_with('-') || w == "-" { positional.push(w.as_str()); continue; }
        if w == "--" { flags_done = true; continue; }
        if let Some(long) = w.strip_prefix("--") {
            let name = format!("--{}", long.split('=').next().unwrap_or(""));
            if !tool.long.contains(&name.as_str()) { return false; }
        } else if !w[1..].chars().all(|c| c.is_ascii_digit()) {
            match short_flags_ok(tool.name, &w[1..], tool.short) { None => return false, Some(s) => scripts.extend(s) }
        }
    }
    match tool.name {
        "uniq" => positional.len() <= 1,
        // Скрипт приклеен к `-e` или идёт первым словом (после `-e` или без него).
        "sed" => if scripts.is_empty() { positional.first().map(|s| sed_script_ok(s)).unwrap_or(false) }
                 else { scripts.iter().all(|s| sed_script_ok(s)) },
        // `|` в программе awk — запуск команды (`print "x" | "sh"`), как и system/getline.
        "awk" => !rest.iter().any(|w| w.contains("system") || w.contains("getline") || w.contains('|') || w.contains('>')),
        _ => true,
    }
}

/// Можно ли выполнить в режиме «только чтение»: строгий белый список утилит и их флагов,
/// без перенаправлений, подстановок, цепочек и sudo.
#[uniffi::export]
pub fn mcp_is_read_only(command: String) -> bool {
    let t = command.trim();
    if t.is_empty() { return false; }
    if [";", "&", ">", "<", "`", "$", "\n", "\r", "\\"].iter().any(|b| t.contains(b)) { return false; }
    match segments(t) {
        Some(segs) => segs.iter().all(|w| segment_ok(w)),
        None => false,
    }
}

// MARK: - Журнал

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct McpLogEntry {
    pub id: String,
    /// ISO 8601, как пишет Swift.
    pub date: String,
    pub client: String,
    pub tool: String,
    pub host: String,
    pub detail: String,
    pub decision: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub changes: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub output: Option<String>,
    /// Машинный код решения; `decision` — текст для человека. У старых записей журнала нет.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    #[uniffi(default = None)]
    pub decision_code: Option<McpDecision>,
}

/// Чем закончилась попытка агента — для фильтров и значков в клиентах, независимо от языка текста.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum McpDecision { DeniedRule, DeniedNoAccess, DeniedReadOnly, RejectedByUser, AllowedRule, AllowedRead, ApprovedByUser, AllowedGrant, AllowedTrusted }

impl McpDecision {
    fn text(self) -> &'static str {
        match self {
            McpDecision::DeniedRule => "запрещено: правило",
            McpDecision::DeniedNoAccess => "запрещено: нет доступа",
            McpDecision::DeniedReadOnly => "запрещено: только чтение",
            McpDecision::RejectedByUser => "отклонено пользователем",
            McpDecision::AllowedRule => "разрешено: правило",
            McpDecision::AllowedRead => "разрешено: чтение",
            McpDecision::ApprovedByUser => "одобрено пользователем",
            McpDecision::AllowedGrant => "разрешено: временный доступ",
            McpDecision::AllowedTrusted => "разрешено: доверенный",
        }
    }
}

/// Пароли и токены не попадают в журнал: `password=…`, `--token x`, `Authorization: Bearer …` → `***`.
#[uniffi::export]
pub fn mcp_mask_secrets(text: String) -> String {
    use std::sync::OnceLock;
    static RULES: OnceLock<[regex::Regex; 3]> = OnceLock::new();
    let r = RULES.get_or_init(|| [
        regex::Regex::new(r"(?i)(authorization\s*:\s*(?:bearer|basic|token)?\s*)[^\s'\x22]+").unwrap(),
        regex::Regex::new(r"(?i)((?:password|passwd|pwd|pass|token|secret|api[_-]?key|access[_-]?key)\s*[=:]\s*['\x22]?)[^\s'\x22&;]+").unwrap(),
        regex::Regex::new(r"(?i)(--(?:password|passwd|pass|token|secret|api-key)\s+['\x22]?)[^\s'\x22]+").unwrap(),
    ]);
    let mut out = text;
    for re in r { out = re.replace_all(&out, "${1}***").into_owned(); }
    out
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpSessionSummary {
    pub id: String,
    pub client: String,
    pub started: String,
    pub hosts: Vec<String>,
    pub changes: Vec<McpLogEntry>,
}

#[uniffi::export]
pub fn mcp_log_line(entry: McpLogEntry) -> String { serde_json::to_string(&entry).unwrap_or_default() }

/// Последние `limit` записей JSON Lines, новые сверху.
#[uniffi::export]
pub fn mcp_log_parse(text: String, limit: u32) -> Vec<McpLogEntry> {
    let lines: Vec<&str> = text.lines().collect();
    lines.iter().rev().take(limit as usize).filter_map(|l| serde_json::from_str(l).ok()).collect()
}

/// «Что изменил агент»: выполненные изменяющие команды по сессиям, новые сверху.
#[uniffi::export]
pub fn mcp_summaries(entries: Vec<McpLogEntry>) -> Vec<McpSessionSummary> {
    let mut groups: Vec<(String, Vec<McpLogEntry>)> = Vec::new();
    for e in entries.into_iter().filter(|e| e.changes == Some(true) && e.exit_code.is_some() && e.session.is_some()) {
        let s = e.session.clone().unwrap();
        match groups.iter_mut().find(|g| g.0 == s) { Some(g) => g.1.push(e), None => groups.push((s, vec![e])) }
    }
    let mut out: Vec<McpSessionSummary> = groups.into_iter().map(|(id, mut list)| {
        list.sort_by(|a, b| a.date.cmp(&b.date));
        let mut hosts: Vec<String> = Vec::new();
        for e in &list { if !hosts.contains(&e.host) { hosts.push(e.host.clone()); } }
        McpSessionSummary { id, client: list[0].client.clone(), started: list[0].date.clone(), hosts, changes: list }
    }).collect();
    out.sort_by(|a, b| b.started.cmp(&a.started));
    out
}

// MARK: - Сервер

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ExecResult { pub status: i32, pub stdout: String, pub stderr: String }

/// Что даёт клиент: хосты, политика, выполнение по ssh, окно подтверждения, запись в журнал.
#[uniffi::export(with_foreign)]
pub trait McpBackend: Send + Sync {
    fn hosts(&self) -> Vec<SshHost>;
    fn policy(&self) -> McpPolicy;
    fn execute(&self, host: SshHost, command: String, timeout_seconds: u32) -> ExecResult;
    fn confirm(&self, host: SshHost, command: String, client: String) -> bool;
    fn log(&self, entry: McpLogEntry);
}

#[derive(uniffi::Object)]
pub struct McpServer {
    backend: std::sync::Arc<dyn McpBackend>,
    client: Mutex<String>,
    session: String,
}

pub const MCP_VERSION: &str = "0.5.0";

fn tools() -> Value {
    json!([
        {"name": "list_hosts", "description": "Список SSH-хостов пользователя с адресом, ОС, группой, метками и уровнем доступа агента.",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "run_command", "description": "Выполнить shell-команду на хосте по SSH. В режиме «только чтение» разрешены лишь безопасные команды без перенаправлений; в режиме «с подтверждением» пользователь одобряет каждую команду.",
         "inputSchema": {"type": "object", "properties": {
             "host": {"type": "string", "description": "Алиас хоста из list_hosts"},
             "command": {"type": "string", "description": "Команда для выполнения"},
             "timeout_seconds": {"type": "integer", "description": "Таймаут, по умолчанию 60, максимум 600"}},
          "required": ["host", "command"]}},
        {"name": "read_file", "description": "Прочитать файл на хосте (не больше max_bytes, по умолчанию 65536). Считается операцией чтения.",
         "inputSchema": {"type": "object", "properties": {"host": {"type": "string"}, "path": {"type": "string"}, "max_bytes": {"type": "integer"}},
          "required": ["host", "path"]}}
    ])
}

fn mode_raw(m: McpMode) -> &'static str {
    match m { McpMode::Off => "off", McpMode::ReadOnly => "readOnly", McpMode::Confirm => "confirm", McpMode::Trusted => "trusted" }
}

#[uniffi::export]
impl McpServer {
    #[uniffi::constructor]
    pub fn new(backend: std::sync::Arc<dyn McpBackend>) -> Self {
        McpServer { backend, client: Mutex::new("агент".into()), session: crate::models::new_id() }
    }

    /// Одно сообщение JSON-RPC; None — ответ не нужен (уведомление).
    pub fn handle(&self, line: String) -> Option<String> {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else {
            return Some(json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}).to_string());
        };
        let id = msg.get("id")?.clone();
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or(json!({}));
        let result = match method {
            "initialize" => {
                if let Some(n) = params.pointer("/clientInfo/name").and_then(Value::as_str) { *self.client.lock().unwrap() = n.into(); }
                json!({
                    "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or("2025-06-18"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "relaya", "version": MCP_VERSION},
                    "instructions": "Доступ к SSH-серверам пользователя из ~/.ssh/config. Права на каждый хост задаёт пользователь в приложении Relaya; команды на хостах «с подтверждением» он одобряет вручную."
                })
            }
            "ping" => json!({}),
            "tools/list" => json!({"tools": tools()}),
            "tools/call" => {
                let name = params.get("name").and_then(Value::as_str).unwrap_or("");
                let args = params.get("arguments").cloned().unwrap_or(json!({}));
                let (text, is_error) = self.call(name, &args);
                json!({"content": [{"type": "text", "text": text}], "isError": is_error})
            }
            _ => return Some(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("Method not found: {method}")}}).to_string()),
        };
        Some(json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string())
    }
}

impl McpServer {
    fn record(&self, tool: &str, host: &str, detail: &str, decision: McpDecision, exit: Option<i32>, changes: bool, output: Option<String>) {
        self.backend.log(McpLogEntry {
            id: crate::models::new_id(), date: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            client: self.client.lock().unwrap().clone(), tool: tool.into(), host: host.into(), detail: mcp_mask_secrets(detail.into()),
            decision: decision.text().into(), exit_code: exit, session: Some(self.session.clone()), changes: Some(changes),
            output: output.map(mcp_mask_secrets), decision_code: Some(decision),
        });
    }

    fn call(&self, name: &str, args: &Value) -> (String, bool) {
        let policy = self.backend.policy();
        if !policy.enabled { return ("Доступ агентов выключен в Relaya (раздел «Агенты»).".into(), true); }
        let now = now_ref();
        match name {
            "list_hosts" => {
                let list: Vec<Value> = self.backend.hosts().into_iter()
                    .filter(|h| !h.is_git_service() && policy.mode(&h.alias, now) != McpMode::Off).map(|h| json!({
                    "host": h.alias, "address": h.subtitle(), "os": h.os.map(|o| o.title()).unwrap_or("неизвестно"),
                    "group": h.group.clone().unwrap_or_default(), "tags": h.tags, "access": mode_raw(policy.mode(&h.alias, now)),
                })).collect();
                (json!({"hosts": list}).to_string(), false)
            }
            "run_command" | "read_file" => {
                let alias = args.get("host").and_then(Value::as_str).unwrap_or("");
                let Some(host) = self.backend.hosts().into_iter().find(|h| h.alias == alias && !h.is_git_service()) else {
                    return ("Хост не найден. Вызовите list_hosts.".into(), true);
                };
                let (command, is_read) = if name == "read_file" {
                    let Some(path) = args.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()) else { return ("Укажите path.".into(), true) };
                    let limit = args.get("max_bytes").and_then(Value::as_i64).unwrap_or(65536).clamp(1, 1_048_576);
                    (format!("head -c {limit} -- {}", shell_quote(path)), true)
                } else {
                    let Some(c) = args.get("command").and_then(Value::as_str).filter(|c| !c.is_empty()) else { return ("Укажите command.".into(), true) };
                    (c.to_string(), mcp_is_read_only(c.to_string()))
                };
                let timeout = args.get("timeout_seconds").and_then(Value::as_i64).unwrap_or(60).clamp(1, 600) as u32;
                if policy.is_denied(&command, alias) {
                    self.record(name, alias, &command, McpDecision::DeniedRule, None, false, None);
                    return (format!("Команда запрещена правилом пользователя для {alias}."), true);
                }
                let mode = policy.mode(alias, now);
                let decision = if mode != McpMode::Off && !is_read && policy.is_allowed(&command, alias) {
                    McpDecision::AllowedRule
                } else {
                    match mode {
                        McpMode::Off => {
                            self.record(name, alias, &command, McpDecision::DeniedNoAccess, None, false, None);
                            return (format!("У агента нет доступа к хосту {alias}."), true);
                        }
                        McpMode::ReadOnly => {
                            if !is_read {
                                self.record(name, alias, &command, McpDecision::DeniedReadOnly, None, false, None);
                                return (format!("Хост {alias} открыт только для чтения, а эта команда может что-то изменить. Попросите пользователя выполнить её самому или повысить доступ в Relaya."), true);
                            }
                            McpDecision::AllowedRead
                        }
                        McpMode::Confirm => {
                            let client = self.client.lock().unwrap().clone();
                            if !self.backend.confirm(host.clone(), command.clone(), client) {
                                self.record(name, alias, &command, McpDecision::RejectedByUser, None, false, None);
                                return (format!("Пользователь отклонил выполнение команды на {alias}."), true);
                            }
                            McpDecision::ApprovedByUser
                        }
                        McpMode::Trusted => if policy.grant(alias, now).is_some() { McpDecision::AllowedGrant } else { McpDecision::AllowedTrusted },
                    }
                };
                let r = self.backend.execute(host, command.clone(), timeout);
                let tail: String = { let o = format!("{}{}", r.stdout, if r.stderr.is_empty() { String::new() } else { format!("\n{}", r.stderr) }); let c: Vec<char> = o.chars().collect(); c[c.len().saturating_sub(2000)..].iter().collect() };
                self.record(name, alias, &command, decision, Some(r.status), !is_read, Some(tail));
                let mut text = r.stdout.clone();
                if !r.stderr.is_empty() { if !text.is_empty() { text.push('\n'); } text += "[stderr]\n"; text += &r.stderr; }
                if text.chars().count() > 50_000 { text = text.chars().take(50_000).collect::<String>() + "\n…[вывод обрезан]"; }
                text += &format!("\n[exit code: {}]", r.status);
                (text, r.status != 0)
            }
            _ => (format!("Неизвестный инструмент {name}."), true),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    struct Fake { policy: McpPolicy, confirm: bool, ran: Mutex<Vec<String>>, logged: Mutex<Vec<McpLogEntry>> }
    impl McpBackend for Fake {
        fn hosts(&self) -> Vec<SshHost> { vec![SshHost::new("web"), SshHost::new("secret"), SshHost::new("git@forge.lan")] }
        fn policy(&self) -> McpPolicy { self.policy.clone() }
        fn execute(&self, _h: SshHost, c: String, _t: u32) -> ExecResult { self.ran.lock().unwrap().push(c); ExecResult { status: 0, stdout: "ok".into(), stderr: "".into() } }
        fn confirm(&self, _h: SshHost, _c: String, _cl: String) -> bool { self.confirm }
        fn log(&self, e: McpLogEntry) { self.logged.lock().unwrap().push(e); }
    }
    fn server(policy: McpPolicy, confirm: bool) -> (McpServer, Arc<Fake>) {
        let f = Arc::new(Fake { policy, confirm, ran: Mutex::new(vec![]), logged: Mutex::new(vec![]) });
        (McpServer::new(f.clone()), f)
    }
    fn call(s: &McpServer, tool: &str, args: Value) -> Value {
        let line = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}).to_string();
        serde_json::from_str::<Value>(&s.handle(line).unwrap()).unwrap()["result"].clone()
    }

    #[test]
    fn masks_secrets_in_log() {
        assert_eq!(mcp_mask_secrets("mysql -u root --password hunter2 -e x".into()), "mysql -u root --password *** -e x");
        assert_eq!(mcp_mask_secrets("curl -H 'Authorization: Bearer abc.def' u?token=XYZ&a=1".into()), "curl -H 'Authorization: Bearer ***' u?token=***&a=1");
        assert_eq!(mcp_mask_secrets("export DB_PASSWORD=s3cr3t; API_KEY: \"k\"".into()), "export DB_PASSWORD=***; API_KEY: \"***\"");
        assert_eq!(mcp_mask_secrets("uptime".into()), "uptime");
    }

    #[test]
    fn broken_policy_fails_closed() {
        assert!(mcp_policy_decode("".into()).enabled);
        let broken = mcp_policy_decode("{\"enabled\": tru".into());
        assert!(!broken.enabled);
        assert_eq!(broken.default_mode, McpMode::ReadOnly);
        assert!(mcp_policy_is_unreadable("{oops".into()));
        assert!(!mcp_policy_is_unreadable("".into()));
        assert!(!mcp_policy_is_unreadable(mcp_policy_encode(McpPolicy::default())));
    }

    #[test]
    fn read_only_rules() {
        for ok in ["ls -la /var/log", "df -h", "journalctl -u nginx -n 50 | grep error", "docker ps", "tail -50 /var/log/syslog",
                   "grep -i 'a|b c' f", "sed -n '1,20p' f", "sed 's/a/b/g' f", "sed -n /err/p f", "find /var -name '*.log' -mtime -1",
                   "sort -rn f | uniq -c | head -5", "ps aux | sort -rk3 | head", "cut -d: -f1 /etc/passwd",
                   "sed -e 's/a/b/' f", "sed -es/a/b/ f", "awk -F: '{print NF}' f", "git log --oneline -n 5", "systemctl status nginx --no-pager", "ps aux"] {
            assert!(mcp_is_read_only(ok.into()), "{ok}");
        }
        for bad in ["rm -rf /", "sudo ls", "cat a > b", "ls; rm x", "sed -i s/a/b/ f", "sed --in-place s/a/b/ f", "sed 's/a/b/w out' f",
                    "sed 's/a/date/e' f", "sed '1w out' f", "find / -delete", "find / -exec rm {} +", "find / -fprint x", "echo $(id)",
                    "echo $HOME", "sort -o out f", "sort --output=out f", "uniq in out", "journalctl --vacuum-size=1M", "journalctl --rotate",
                    "env", "printenv", "ip link set eth0 down", "ubus call system reboot", "date -s 2020-01-01", "hostname evil", "dmesg -C",
                    "ss -K", "ls --unknown", "grep -P x", "git diff --output=x", "git log --ext-diff", "awk 'BEGIN{system(\"id\")}'",
                    "cat 'unclosed", "less f", "awk 'BEGIN{print \"x\" | \"sh\"}'", "sed -es/a/b/w f",
                    "sed -e 's/a/b/e' f", "cut -x f"] {
            assert!(!mcp_is_read_only(bad.into()), "{bad}");
        }
    }

    #[test]
    fn modes_rules_grants() {
        let mut p = McpPolicy { default_mode: McpMode::ReadOnly, ..Default::default() };
        p.hosts.insert("secret".into(), McpMode::Off);
        let (s, f) = server(p.clone(), false);
        let hosts = call(&s, "list_hosts", json!({}));
        assert!(hosts["content"][0]["text"].as_str().unwrap().contains("web") && !hosts["content"][0]["text"].as_str().unwrap().contains("secret"));
        assert!(!hosts["content"][0]["text"].as_str().unwrap().contains("forge"));
        assert_eq!(call(&s, "run_command", json!({"host": "git@forge.lan", "command": "uptime"}))["isError"], true);
        assert_eq!(call(&s, "run_command", json!({"host": "web", "command": "rm x"}))["isError"], true);
        assert_eq!(call(&s, "run_command", json!({"host": "web", "command": "uptime"}))["isError"], false);
        assert_eq!(f.ran.lock().unwrap().as_slice(), ["uptime"]);

        let mut c = McpPolicy::default();
        c.allow = Some(HashMap::from([("web".into(), vec!["systemctl restart *".into()])]));
        c.deny = Some(HashMap::from([("*".into(), vec!["rm -rf *".into()])]));
        assert!(c.is_allowed("systemctl restart nginx", "web") && !c.is_allowed("systemctl restart nginx; rm -rf /", "web"));
        let (s2, _) = server(c.clone(), false);
        assert_eq!(call(&s2, "run_command", json!({"host": "web", "command": "systemctl restart nginx"}))["isError"], false);
        assert_eq!(call(&s2, "run_command", json!({"host": "web", "command": "touch x"}))["isError"], true);
        assert_eq!(call(&s2, "run_command", json!({"host": "web", "command": "rm -rf /tmp/x"}))["isError"], true);
        c.grants = Some(HashMap::from([("web".into(), McpGrant { mode: McpMode::Trusted, until: now_ref() + 600.0 })]));
        assert_eq!(c.mode("web", now_ref()), McpMode::Trusted);
        assert_eq!(c.mode("web", now_ref() + 3600.0), McpMode::Confirm);
    }

    #[test]
    fn swift_policy_json_and_summaries() {
        let swift = r#"{"defaultMode":"confirm","enabled":true,"grants":{"db":{"mode":"trusted","until":815000000.5}},"hosts":{"prod":"off","web":"readOnly"}}"#;
        let p = mcp_policy_decode(swift.into());
        assert_eq!(p.hosts["web"], McpMode::ReadOnly);
        assert_eq!(p.grants.as_ref().unwrap()["db"].until, 815000000.5);
        let e = McpLogEntry { id: "1".into(), date: "2026-10-31T10:00:00Z".into(), client: "Claude".into(), tool: "run_command".into(),
            host: "web".into(), detail: "systemctl restart nginx".into(), decision: "x".into(), exit_code: Some(0), session: Some("s".into()), changes: Some(true), output: None, decision_code: None };
        let mut read = e.clone(); read.changes = Some(false); read.detail = "ls".into();
        let s = mcp_summaries(vec![e, read]);
        assert_eq!((s.len(), s[0].changes.len(), s[0].hosts.clone()), (1, 1, vec!["web".to_string()]));
    }
}
