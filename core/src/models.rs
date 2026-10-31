//! Сниппеты, туннели и удалённые столы — те же JSON-файлы, что пишет Swift (поля и регистр UUID совпадают).

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Новый идентификатор в том же виде, что у Swift `UUID().uuidString` (верхний регистр).
pub fn new_id() -> String { uuid::Uuid::new_v4().to_string().to_uppercase() }

#[uniffi::export]
pub fn core_new_id() -> String { new_id() }

// MARK: - Сниппеты

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Snippet {
    pub id: String,
    pub name: String,
    pub command: String,
    pub tags: Vec<String>,
}

fn variable_regex() -> Regex { Regex::new(r"\{\{\s*([\p{L}_][^{}\s]*)\s*\}\}").unwrap() }

/// Имена переменных `{{имя}}` в порядке появления, без повторов.
#[uniffi::export]
pub fn snippet_variables(command: String) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    variable_regex().captures_iter(&command)
        .filter_map(|c| { let n = c[1].to_string(); seen.insert(n.clone()).then_some(n) })
        .collect()
}

/// Команда с подставленными значениями; незаполненные переменные остаются как есть.
#[uniffi::export]
pub fn snippet_filled(command: String, values: HashMap<String, String>) -> String {
    variable_regex().replace_all(&command, |c: &regex::Captures| {
        values.get(&c[1]).cloned().unwrap_or_else(|| c[0].to_string())
    }).into_owned()
}

// MARK: - Туннели

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum TunnelKind { Local, Remote, Dynamic }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct Tunnel {
    pub id: String,
    pub name: String,
    pub host_alias: String,
    pub kind: TunnelKind,
    pub listen_port: i64,
    pub target_host: String,
    pub target_port: i64,
    pub auto_start: bool,
}

/// Только по паролю: без перебора ключей агента (иначе «Too many authentication failures»).
pub const PASSWORD_ONLY_OPTIONS: &[&str] = &["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"];

/// `8080:localhost:80` или `1080`.
#[uniffi::export]
pub fn tunnel_spec(t: Tunnel) -> String {
    if t.kind == TunnelKind::Dynamic { t.listen_port.to_string() } else { format!("{}:{}:{}", t.listen_port, t.target_host, t.target_port) }
}

/// Аргументы `ssh -N` без секретов; пароль, если нужен, — через askpass клиента.
#[uniffi::export]
pub fn tunnel_ssh_arguments(t: Tunnel, password_only: bool) -> Vec<String> {
    let mut a: Vec<String> = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                              "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15"]
        .iter().map(|s| s.to_string()).collect();
    if password_only { a.extend(PASSWORD_ONLY_OPTIONS.iter().map(|s| s.to_string())) } else { a.extend(["-o".into(), "BatchMode=yes".into()]) }
    let flag = match t.kind { TunnelKind::Local => "-L", TunnelKind::Remote => "-R", TunnelKind::Dynamic => "-D" };
    let alias = t.host_alias.clone();
    a.extend([flag.to_string(), tunnel_spec(t), alias]);
    a
}

#[uniffi::export]
pub fn password_only_options() -> Vec<String> { PASSWORD_ONLY_OPTIONS.iter().map(|s| s.to_string()).collect() }

// MARK: - Удалённые столы

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum DesktopKind { Vnc, Rdp }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct RemoteDesktop {
    pub id: String,
    pub name: String,
    pub kind: DesktopKind,
    pub address: String,
    pub port: i64,
    pub user: String,
    #[serde(rename = "viaSSHHost", skip_serializing_if = "Option::is_none", default)]
    pub via_ssh_host: Option<String>,
    pub full_screen: bool,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub scale_to_fit: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub rdp_width: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub rdp_height: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub rdp_retina: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub group: Option<String>,
}

/// Содержимое .rdp-файла для Windows App / mstsc.
#[uniffi::export]
pub fn desktop_rdp_file(d: RemoteDesktop, host: String, port: i64) -> String {
    let mut lines = vec![
        format!("full address:s:{host}:{port}"),
        format!("screen mode id:i:{}", if d.full_screen { 2 } else { 1 }),
        "prompt for credentials:i:1".into(), "redirectclipboard:i:1".into(), "audiomode:i:0".into(),
        "use multimon:i:0".into(), "dynamic resolution:i:1".into(),
    ];
    if !d.user.is_empty() { lines.push(format!("username:s:{}", d.user)); }
    lines.join("\r\n") + "\r\n"
}

// MARK: - JSON-файлы

pub fn decode_list<T: for<'de> Deserialize<'de>>(json: &str) -> Vec<T> { serde_json::from_str(json).unwrap_or_default() }

/// Пустой текст — пустой список; нечитаемый — ошибка, а не `[]`: иначе следующая запись затёрла бы файл пользователя.
pub fn try_decode_list<T: for<'de> Deserialize<'de>>(json: &str) -> Result<Vec<T>, crate::error::CoreError> {
    if json.trim().is_empty() { return Ok(Vec::new()); }
    Ok(serde_json::from_str(json)?)
}

/// Как Swift `JSONEncoder` с `.prettyPrinted, .sortedKeys` (порядок ключей важен для синхронизации — меньше диффов).
pub fn encode_sorted<T: Serialize>(value: &T) -> String {
    let v = serde_json::to_value(value).unwrap_or(serde_json::Value::Null);
    let mut out = Vec::new();
    let mut ser = serde_json::Serializer::with_formatter(&mut out, SwiftPretty::default());
    if sort_keys(v).serialize(&mut ser).is_err() { return String::new(); }
    String::from_utf8(out).unwrap_or_default()
}

/// Отступ в 2 пробела и `"key" : value`, как у `JSONEncoder.prettyPrinted` (у serde — `"key": value`).
#[derive(Default)]
struct SwiftPretty<'a>(serde_json::ser::PrettyFormatter<'a>);

impl serde_json::ser::Formatter for SwiftPretty<'_> {
    fn begin_array<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> { self.0.begin_array(w) }
    fn end_array<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> { self.0.end_array(w) }
    fn begin_array_value<W: ?Sized + std::io::Write>(&mut self, w: &mut W, first: bool) -> std::io::Result<()> { self.0.begin_array_value(w, first) }
    fn end_array_value<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> { self.0.end_array_value(w) }
    fn begin_object<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> { self.0.begin_object(w) }
    fn end_object<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> { self.0.end_object(w) }
    fn begin_object_key<W: ?Sized + std::io::Write>(&mut self, w: &mut W, first: bool) -> std::io::Result<()> { self.0.begin_object_key(w, first) }
    fn begin_object_value<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> { w.write_all(b" : ") }
    fn end_object_value<W: ?Sized + std::io::Write>(&mut self, w: &mut W) -> std::io::Result<()> { self.0.end_object_value(w) }
}

fn sort_keys(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(m) => {
            let mut keys: Vec<_> = m.into_iter().collect();
            keys.sort_by(|a, b| a.0.cmp(&b.0));
            serde_json::Value::Object(keys.into_iter().map(|(k, v)| (k, sort_keys(v))).collect())
        }
        serde_json::Value::Array(a) => serde_json::Value::Array(a.into_iter().map(sort_keys).collect()),
        x => x,
    }
}

#[uniffi::export]
pub fn snippets_decode(json: String) -> Vec<Snippet> { decode_list(&json) }
#[uniffi::export]
pub fn snippets_encode(list: Vec<Snippet>) -> String { encode_sorted(&list) }
#[uniffi::export]
pub fn tunnels_decode(json: String) -> Vec<Tunnel> { decode_list(&json) }
#[uniffi::export]
pub fn tunnels_encode(list: Vec<Tunnel>) -> String { encode_sorted(&list) }
#[uniffi::export]
pub fn desktops_decode(json: String) -> Vec<RemoteDesktop> { decode_list(&json) }
#[uniffi::export]
pub fn snippets_decode_checked(json: String) -> Result<Vec<Snippet>, crate::error::CoreError> { try_decode_list(&json) }
#[uniffi::export]
pub fn tunnels_decode_checked(json: String) -> Result<Vec<Tunnel>, crate::error::CoreError> { try_decode_list(&json) }
#[uniffi::export]
pub fn desktops_decode_checked(json: String) -> Result<Vec<RemoteDesktop>, crate::error::CoreError> { try_decode_list(&json) }
#[uniffi::export]
pub fn desktops_encode(list: Vec<RemoteDesktop>) -> String { encode_sorted(&list) }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snippet_variables_and_fill() {
        let cmd = "journalctl -u {{service}} -n {{ lines }} | grep {{service}}".to_string();
        assert_eq!(snippet_variables(cmd.clone()), ["service", "lines"]);
        let mut v = HashMap::new();
        v.insert("service".to_string(), "nginx".to_string());
        assert_eq!(snippet_filled(cmd, v), "journalctl -u nginx -n {{ lines }} | grep nginx");
        // `{{.Names}}` в docker — не переменная.
        assert!(snippet_variables("docker ps --format '{{.Names}}'".into()).is_empty());
    }

    #[test]
    fn swift_json_compatibility() {
        let swift = r#"[{"autoStart":true,"hostAlias":"db","id":"6F1B2C3D-0000-4000-8000-000000000001","kind":"local","listenPort":15432,"name":"pg","targetHost":"localhost","targetPort":5432}]"#;
        let t = tunnels_decode(swift.into());
        assert_eq!(t[0].host_alias, "db");
        assert_eq!(tunnel_spec(t[0].clone()), "15432:localhost:5432");
        let enc = tunnels_encode(t);
        assert!(enc.contains("\"autoStart\" : true") && enc.starts_with("[\n  {\n    \""), "{enc}");
        assert!(tunnels_decode_checked("[{oops".into()).is_err());
        assert_eq!(tunnels_decode_checked(" ".into()).unwrap(), vec![]);
        let d = r#"[{"address":"10.0.0.5","fullScreen":false,"id":"A","kind":"rdp","name":"win","port":3389,"user":"u","viaSSHHost":"bastion"}]"#;
        let list = desktops_decode(d.into());
        assert_eq!(list[0].via_ssh_host.as_deref(), Some("bastion"));
        let back = desktops_encode(list);
        assert!(back.contains("\"viaSSHHost\"") && !back.contains("rdpWidth"));
    }
}

// MARK: - SFTP

/// Файл или папка на сервере (строка `ls -la` из sftp).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RemoteFile {
    pub name: String,
    pub is_directory: bool,
    pub is_link: bool,
    pub size: i64,
    pub permissions: String,
    pub modified: String,
}

/// `drwxr-xr-x  2 root root 4096 Oct 29 12:00 name with spaces` → файлы; папки сверху, по имени.
#[uniffi::export]
pub fn sftp_parse_listing(output: String) -> Vec<RemoteFile> {
    let re = Regex::new(r"^([-dlcbps]\S*)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s(.+)$").unwrap();
    let mut files: Vec<RemoteFile> = output.lines().filter_map(|line| {
        let c = re.captures(line)?;
        let perms = c[1].to_string();
        let mut name = c[6].to_string();
        let first = perms.chars().next()?;
        if first == 'l' { if let Some(i) = name.find(" -> ") { name.truncate(i); } }
        if name == "." || name == ".." { return None; }
        Some(RemoteFile { name, is_directory: first == 'd', is_link: first == 'l', size: c[2].parse().unwrap_or(0),
                          permissions: perms, modified: format!("{} {} {}", &c[3], &c[4], &c[5]) })
    }).collect();
    files.sort_by(|a, b| b.is_directory.cmp(&a.is_directory).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    files
}

#[cfg(test)]
mod sftp_tests {
    use super::*;
    #[test]
    fn listing() {
        let out = "drwxr-xr-x    2 root     root         4096 Oct 29 12:00 logs\n-rw-r--r--    1 root     root           12 Mar  3  2024 my file.txt\nlrwxrwxrwx    1 root     root            7 Oct 29 12:00 link -> target\ndrwxr-xr-x    2 root     root         4096 Oct 29 12:00 .\n";
        let f = sftp_parse_listing(out.into());
        assert_eq!(f.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(), ["logs", "link", "my file.txt"]);
        assert_eq!(f[2].size, 12);
        assert_eq!(f[2].modified, "Mar 3 2024");
        assert!(f[1].is_link);
    }
}
