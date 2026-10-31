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
#[uniffi::export]
pub fn mcp_policy_decode(json: String) -> McpPolicy { serde_json::from_str(&json).unwrap_or_default() }
#[uniffi::export]
pub fn mcp_policy_encode(policy: McpPolicy) -> String { crate::models::encode_sorted(&policy) }

// MARK: - Только чтение

const READ_ONLY: &[&str] = &["ls", "cat", "head", "tail", "grep", "egrep", "zgrep", "less", "wc", "sort", "uniq", "cut", "awk", "sed",
    "df", "du", "free", "uptime", "uname", "hostname", "whoami", "id", "date", "ps", "pgrep", "top", "stat", "file", "find", "which",
    "lsblk", "lscpu", "lsof", "ss", "netstat", "ip", "ping", "dig", "nslookup", "journalctl", "dmesg", "env", "printenv", "echo", "pwd",
    "tree", "md5sum", "sha256sum", "ubus", "logread", "iwinfo", "sw_vers"];
const READ_ONLY_EXTRA: &[&str] = &["vm_stat", "nproc"];
const READ_ONLY_PAIRS: &[&str] = &["systemctl status", "systemctl list-units", "systemctl --failed", "systemctl is-active",
    "docker ps", "docker logs", "docker images", "docker inspect", "docker stats", "kubectl get", "kubectl describe", "kubectl logs",
    "git status", "git log", "git diff", "apt list", "dpkg -l", "rpm -qa", "opkg list-installed", "uci show"];

/// Можно ли выполнить в режиме «только чтение»: безопасные команды без перенаправлений, подстановок и sudo.
#[uniffi::export]
pub fn mcp_is_read_only(command: String) -> bool {
    let t = command.trim();
    if t.is_empty() { return false; }
    if [";", "&", ">", "<", "`", "$(", "\n", "\\"].iter().any(|b| t.contains(b)) { return false; }
    for seg in t.split('|') {
        let words: Vec<&str> = seg.split_whitespace().collect();
        let Some(first) = words.first() else { return false };
        if *first == "sudo" { return false; }
        if *first == "sed" && words.iter().any(|w| w.starts_with("-i")) { return false; }
        if *first == "find" && words.iter().any(|w| ["-delete", "-exec", "-execdir", "-fprint", "-ok"].contains(w)) { return false; }
        if *first == "awk" && seg.contains("system(") { return false; }
        let pair = words.iter().take(2).copied().collect::<Vec<_>>().join(" ");
        if !READ_ONLY.contains(first) && !READ_ONLY_EXTRA.contains(first) && !READ_ONLY_PAIRS.contains(&pair.as_str())
            && pair != "nginx -t" { return false; }
    }
    true
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
    fn record(&self, tool: &str, host: &str, detail: &str, decision: &str, exit: Option<i32>, changes: bool, output: Option<String>) {
        self.backend.log(McpLogEntry {
            id: crate::models::new_id(), date: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            client: self.client.lock().unwrap().clone(), tool: tool.into(), host: host.into(), detail: detail.into(),
            decision: decision.into(), exit_code: exit, session: Some(self.session.clone()), changes: Some(changes), output,
        });
    }

    fn call(&self, name: &str, args: &Value) -> (String, bool) {
        let policy = self.backend.policy();
        if !policy.enabled { return ("Доступ агентов выключен в Relaya (раздел «Агенты»).".into(), true); }
        let now = now_ref();
        match name {
            "list_hosts" => {
                let list: Vec<Value> = self.backend.hosts().into_iter().filter(|h| policy.mode(&h.alias, now) != McpMode::Off).map(|h| json!({
                    "host": h.alias, "address": h.subtitle(), "os": h.os.map(|o| o.title()).unwrap_or("неизвестно"),
                    "group": h.group.clone().unwrap_or_default(), "tags": h.tags, "access": mode_raw(policy.mode(&h.alias, now)),
                })).collect();
                (json!({"hosts": list}).to_string(), false)
            }
            "run_command" | "read_file" => {
                let alias = args.get("host").and_then(Value::as_str).unwrap_or("");
                let Some(host) = self.backend.hosts().into_iter().find(|h| h.alias == alias) else {
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
                    self.record(name, alias, &command, "запрещено: правило", None, false, None);
                    return (format!("Команда запрещена правилом пользователя для {alias}."), true);
                }
                let mode = policy.mode(alias, now);
                let decision = if mode != McpMode::Off && !is_read && policy.is_allowed(&command, alias) {
                    "разрешено: правило"
                } else {
                    match mode {
                        McpMode::Off => {
                            self.record(name, alias, &command, "запрещено: нет доступа", None, false, None);
                            return (format!("У агента нет доступа к хосту {alias}."), true);
                        }
                        McpMode::ReadOnly => {
                            if !is_read {
                                self.record(name, alias, &command, "запрещено: только чтение", None, false, None);
                                return (format!("Хост {alias} открыт только для чтения, а эта команда может что-то изменить. Попросите пользователя выполнить её самому или повысить доступ в Relaya."), true);
                            }
                            "разрешено: чтение"
                        }
                        McpMode::Confirm => {
                            let client = self.client.lock().unwrap().clone();
                            if !self.backend.confirm(host.clone(), command.clone(), client) {
                                self.record(name, alias, &command, "отклонено пользователем", None, false, None);
                                return (format!("Пользователь отклонил выполнение команды на {alias}."), true);
                            }
                            "одобрено пользователем"
                        }
                        McpMode::Trusted => if policy.grant(alias, now).is_some() { "разрешено: временный доступ" } else { "разрешено: доверенный" },
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
        fn hosts(&self) -> Vec<SshHost> { vec![SshHost::new("web"), SshHost::new("secret")] }
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
    fn read_only_rules() {
        for ok in ["ls -la /var/log", "df -h", "journalctl -u nginx -n 50 | grep error", "docker ps"] { assert!(mcp_is_read_only(ok.into()), "{ok}"); }
        for bad in ["rm -rf /", "sudo ls", "cat a > b", "ls; rm x", "sed -i s/a/b/ f", "find / -delete", "echo $(id)"] { assert!(!mcp_is_read_only(bad.into()), "{bad}"); }
    }

    #[test]
    fn modes_rules_grants() {
        let mut p = McpPolicy { default_mode: McpMode::ReadOnly, ..Default::default() };
        p.hosts.insert("secret".into(), McpMode::Off);
        let (s, f) = server(p.clone(), false);
        let hosts = call(&s, "list_hosts", json!({}));
        assert!(hosts["content"][0]["text"].as_str().unwrap().contains("web") && !hosts["content"][0]["text"].as_str().unwrap().contains("secret"));
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
            host: "web".into(), detail: "systemctl restart nginx".into(), decision: "x".into(), exit_code: Some(0), session: Some("s".into()), changes: Some(true), output: None };
        let mut read = e.clone(); read.changes = Some(false); read.detail = "ls".into();
        let s = mcp_summaries(vec![e, read]);
        assert_eq!((s.len(), s[0].changes.len(), s[0].hosts.clone()), (1, 1, vec!["web".to_string()]));
    }
}
