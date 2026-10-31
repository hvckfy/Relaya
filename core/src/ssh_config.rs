//! `~/.ssh/config`: разбор в список хостов и построчные правки блоков (как SSHConfigParser/SSHConfigDocument в Swift).

use crate::error::CoreError;
use crate::server_os::ServerOs;

/// Хост из `~/.ssh/config` с метаданными Relaya из комментария `# relaya: …` над блоком.
#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct SshHost {
    pub alias: String,
    pub host_name: Option<String>,
    pub user: Option<String>,
    pub port: Option<i64>,
    pub identity_file: Option<String>,
    pub proxy_jump: Option<String>,
    pub forward_agent: Option<bool>,
    pub server_alive_interval: Option<i64>,
    pub compression: Option<bool>,
    pub group: Option<String>,
    pub tags: Vec<String>,
    pub color: Option<String>,
    pub os: Option<ServerOs>,
    pub tmux: bool,
    /// Все IdentityFile блока по порядку; `identity_file` — первый из них. Пусто при рендере — берётся `identity_file`.
    #[uniffi(default = [])]
    pub identity_files: Vec<String>,
    /// ForwardAgent как в конфиге: None — директивы нет (наследуется), иначе значение (`yes`/`no`).
    /// При рендере важнее `forward_agent`: Some(bool) — явный выбор, None — оставить как в конфиге.
    #[uniffi(default = None)]
    pub forward_agent_value: Option<String>,
    /// Compression как в конфиге, по тем же правилам.
    #[uniffi(default = None)]
    pub compression_value: Option<String>,
}

/// Для какой системы пишется конфиг: UseKeychain понимает только ssh на macOS.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConfigPlatform { Macos, Windows, Linux }

impl ConfigPlatform {
    /// Система, на которой работает ядро (Linux — и для прочих Unix, кроме macOS).
    pub fn current() -> Self {
        if cfg!(target_os = "macos") { ConfigPlatform::Macos } else if cfg!(windows) { ConfigPlatform::Windows } else { ConfigPlatform::Linux }
    }
}

impl SshHost {
    pub fn new(alias: &str) -> Self {
        SshHost { alias: alias.to_string(), ..Default::default() }
    }

    /// Запись для git-хостинга, а не сервер.
    pub fn is_git_service(&self) -> bool {
        let name = self.host_name.as_deref().unwrap_or(&self.alias).to_lowercase();
        const KNOWN: &[&str] = &["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
                                   "codeberg.org", "gitea.com", "ssh.github.com", "altssh.gitlab.com", "altssh.bitbucket.org"];
        // `git@host` в имени — git-сервер, введённый как адрес клона (старые записи «Новый хост»).
        let typed_as_git = self.alias.to_lowercase().starts_with("git@") || name.starts_with("git@");
        self.user.as_deref() == Some("git") || typed_as_git || KNOWN.contains(&name.as_str())
    }

    /// `user@hostname:port`.
    pub fn subtitle(&self) -> String {
        let mut s = self.host_name.clone().unwrap_or_else(|| self.alias.clone());
        if let Some(u) = &self.user { s = format!("{u}@{s}"); }
        if let Some(p) = self.port { if p != 22 { s = format!("{s}:{p}"); } }
        s
    }
}

#[uniffi::export]
pub fn host_is_git_service(host: SshHost) -> bool { host.is_git_service() }

/// Разобранный ввод адреса `user@host:port`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Destination {
    pub user: Option<String>,
    pub host: String,
    pub port: Option<i64>,
}

/// `git@a.b` → (git, a.b), `root@1.2.3.4:2222` → (root, 1.2.3.4, 2222), `[::1]:22` → (::1, 22).
/// Голый IPv6 (`::1`, `fe80::1`) — целиком хост; нечисловой «порт» остаётся частью хоста.
#[uniffi::export]
pub fn parse_destination(input: String) -> Destination {
    let t = input.trim();
    let t = t.strip_prefix("ssh://").unwrap_or(t).trim_end_matches('/');
    let (user, rest) = match t.rfind('@') {
        Some(i) => (Some(t[..i].trim()).filter(|u| !u.is_empty()).map(str::to_string), t[i + 1..].trim()),
        None => (None, t),
    };
    let port_of = |p: &str| p.parse::<i64>().ok().filter(|p| (1..=65535).contains(p));
    let (host, port) = if let Some(r) = rest.strip_prefix('[') {
        match r.find(']') {
            Some(i) => (r[..i].to_string(), r[i + 1..].strip_prefix(':').and_then(port_of)),
            None => (rest.to_string(), None),
        }
    } else {
        match rest.rsplit_once(':') {
            Some((h, p)) if !h.contains(':') && port_of(p).is_some() => (h.to_string(), port_of(p)),
            _ => (rest.to_string(), None),
        }
    };
    Destination { user, host, port }
}

#[uniffi::export]
pub fn host_subtitle(host: SshHost) -> String { host.subtitle() }

#[derive(Default)]
pub(crate) struct Meta {
    pub group: Option<String>,
    pub tags: Vec<String>,
    pub color: Option<String>,
    pub os: Option<ServerOs>,
    pub tmux: bool,
}

/// `Host a b` → `["a", "b"]`.
pub(crate) fn aliases(value: &str) -> Vec<String> {
    value.split_whitespace().map(str::to_string).collect()
}

#[uniffi::export]
pub fn is_pattern(alias: String) -> bool {
    alias.chars().any(|c| "*?!".contains(c))
}

/// Хвост `# …` после значения — комментарий: `#` вне кавычек, перед которым пробел.
pub(crate) fn strip_comment(line: &str) -> &str {
    let mut quoted = false;
    let mut prev_space = false;
    for (i, c) in line.char_indices() {
        match c {
            '"' => quoted = !quoted,
            '#' if !quoted && prev_space => return line[..i].trim_end(),
            _ => {}
        }
        prev_space = c.is_whitespace();
    }
    line
}

/// `Key value`, `Key=value`, `Key = "value"`, `Key value # заметка` → (ключ в нижнем регистре, значение).
pub(crate) fn split_key_value(line: &str) -> (String, String) {
    let line = if line.trim_start().starts_with('#') { line } else { strip_comment(line) };
    let is_sep = |c: char| c.is_whitespace() || c == '=';
    match line.find(is_sep) {
        None => (line.to_lowercase(), String::new()),
        Some(i) => {
            let key = line[..i].to_lowercase();
            let mut value = line[i..].trim_matches(is_sep).to_string();
            if value.chars().count() >= 2 && value.starts_with('"') && value.ends_with('"') {
                value = value[1..value.len() - 1].to_string();
            }
            (key, value)
        }
    }
}

/// `# relaya: group="мои сервера" tags=prod,db color=orange`.
pub(crate) fn parse_meta(line: &str) -> Option<Meta> {
    let body = line.trim_start_matches('#').trim();
    if !body.to_lowercase().starts_with("relaya:") { return None; }
    let mut meta = Meta::default();
    for pair in meta_tokens(&body["relaya:".len()..]) {
        let Some((k, v)) = pair.split_once('=') else { continue };
        match k.to_lowercase().as_str() {
            "group" => meta.group = Some(v.to_string()),
            "tags" => meta.tags.extend(split_tags(v.to_string())),
            "env" => meta.tags.push(v.to_lowercase()),
            "color" => meta.color = Some(v.to_lowercase()),
            "os" => meta.os = ServerOs::from_raw(&v.to_lowercase()),
            "tmux" => meta.tmux = ["on", "yes", "true", "1"].contains(&v.to_lowercase().as_str()),
            _ => {}
        }
    }
    Some(meta)
}

/// Делит по пробелам, но не внутри кавычек; кавычки снимает.
fn meta_tokens(s: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    for ch in s.chars() {
        if ch == '"' {
            quoted = !quoted;
        } else if ch.is_whitespace() && !quoted {
            if !current.is_empty() { tokens.push(std::mem::take(&mut current)); }
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() { tokens.push(current); }
    tokens
}

/// `prod, db` → `["prod", "db"]` без пустых и повторов (без учёта регистра).
#[uniffi::export]
pub fn split_tags(s: String) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    s.split(',').map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty() && seen.insert(t.to_lowercase()))
        .collect()
}

/// Значение для `# relaya:`: в кавычках, если есть пробелы.
pub(crate) fn meta_value(s: &str) -> String {
    let clean = s.replace('"', "");
    if clean.chars().any(char::is_whitespace) { format!("\"{clean}\"") } else { clean }
}

/// Значение директивы: с пробелами — в кавычках (ssh иначе прочтёт только первое слово).
fn quote_value(v: &str) -> String {
    let clean = v.trim_matches('"');
    if clean.chars().any(char::is_whitespace) { format!("\"{clean}\"") } else { clean.to_string() }
}

/// Перевод строки в любом значении дописал бы в конфиг свою директиву.
fn check_host(h: &SshHost) -> Result<(), CoreError> {
    let all = [Some(&h.alias), h.host_name.as_ref(), h.user.as_ref(), h.identity_file.as_ref(), h.proxy_jump.as_ref(),
               h.group.as_ref(), h.color.as_ref(), h.forward_agent_value.as_ref(), h.compression_value.as_ref()];
    for v in all.into_iter().flatten().chain(h.identity_files.iter()).chain(h.tags.iter()) {
        if v.contains(['\n', '\r']) { return Err(CoreError::InvalidValue(v.clone())); }
    }
    Ok(())
}

/// Строка `# relaya: …` или `None`, если метаданных нет; `extra` — незнакомые пары старой строки, как были.
fn meta_line(group: Option<&str>, tags: &[String], color: Option<&str>, os: Option<ServerOs>, tmux: bool, extra: &[String]) -> Option<String> {
    let mut meta = Vec::new();
    if let Some(g) = group.filter(|g| !g.is_empty()) { meta.push(format!("group={}", meta_value(g))); }
    let tags = split_tags(tags.join(","));
    if !tags.is_empty() { meta.push(format!("tags={}", meta_value(&tags.join(",")))); }
    if let Some(c) = color.filter(|c| !c.is_empty()) { meta.push(format!("color={}", meta_value(c))); }
    if let Some(os) = os { meta.push(format!("os={}", os.raw())); }
    if tmux { meta.push("tmux=on".into()); }
    meta.extend(extra.iter().cloned());
    (!meta.is_empty()).then(|| format!("# relaya: {}", meta.join(" ")))
}

const META_KEYS: &[&str] = &["group", "tags", "env", "color", "os", "tmux"];

fn apply(key: &str, value: &str, host: &mut SshHost) {
    // В ssh_config побеждает первое значение.
    match key {
        "hostname" if host.host_name.is_none() => host.host_name = Some(value.to_string()),
        "user" if host.user.is_none() => host.user = Some(value.to_string()),
        "port" if host.port.is_none() => host.port = value.parse().ok(),
        "identityfile" => {
            if host.identity_file.is_none() { host.identity_file = Some(value.to_string()); }
            host.identity_files.push(value.to_string());
        }
        "proxyjump" if host.proxy_jump.is_none() => host.proxy_jump = Some(value.to_string()),
        "forwardagent" if host.forward_agent.is_none() => {
            host.forward_agent = Some(value.eq_ignore_ascii_case("yes"));
            host.forward_agent_value = Some(value.to_string());
        }
        "serveraliveinterval" if host.server_alive_interval.is_none() => host.server_alive_interval = value.parse().ok(),
        "compression" if host.compression.is_none() => {
            host.compression = Some(value.eq_ignore_ascii_case("yes"));
            host.compression_value = Some(value.to_string());
        }
        _ => {}
    }
}

fn lines_of(text: &str) -> impl Iterator<Item = &str> {
    text.split(['\n', '\r'])
}

/// Хосты из текста `~/.ssh/config`. Шаблоны (`*`, `?`, `!`) и `Match` пропускаются.
#[uniffi::export]
pub fn parse_config(text: String) -> Vec<SshHost> {
    let mut hosts = Vec::new();
    let mut current: Vec<SshHost> = Vec::new();
    let mut pending = Meta::default();
    let mut in_match = false;
    for raw in lines_of(&text) {
        let line = raw.trim();
        if line.is_empty() { continue; }
        if line.starts_with('#') {
            if let Some(m) = parse_meta(line) { pending = m; }
            continue;
        }
        let (key, value) = split_key_value(line);
        match key.as_str() {
            "host" => {
                hosts.append(&mut current);
                in_match = false;
                let meta = std::mem::take(&mut pending);
                current = aliases(&value).into_iter().filter(|a| !is_pattern(a.clone())).map(|a| SshHost {
                    alias: a, group: meta.group.clone(), tags: meta.tags.clone(), color: meta.color.clone(),
                    os: meta.os, tmux: meta.tmux, ..Default::default()
                }).collect();
            }
            "match" => {
                hosts.append(&mut current);
                in_match = true;
            }
            _ if !in_match => for h in current.iter_mut() { apply(&key, &value, h) },
            _ => {}
        }
    }
    hosts.append(&mut current);
    hosts
}

// MARK: - Документ для правок

/// Директивы, которыми управляет редактор; остальные строки блока не трогаются.
// UseKeychain и AddKeysToAgent сюда не входят: уже стоящие в блоке остаются как были.
const MANAGED: &[&str] = &["hostname", "user", "port", "identityfile", "proxyjump", "forwardagent",
                             "serveraliveinterval", "compression"];

/// Где лежит блок хоста.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Block {
    /// Строки блока [start, end), включая `# relaya:` над ним.
    pub start: u32,
    pub end: u32,
    /// Индекс строки `Host`.
    pub host_line: u32,
    /// `Host a b` — правка разорвала бы общий блок.
    pub is_shared: bool,
}

/// Построчная модель конфига: меняет только блок нужного хоста.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Document {
    pub lines: Vec<String>,
}

impl Document {
    pub fn new(text: &str) -> Self {
        let mut lines: Vec<String> = text.split('\n').map(str::to_string).collect();
        if lines.last().map(|l| l.is_empty()).unwrap_or(false) { lines.pop(); }
        Document { lines }
    }

    pub fn text(&self) -> String {
        if self.lines.is_empty() { String::new() } else { self.lines.join("\n") + "\n" }
    }

    pub fn block(&self, alias: &str) -> Option<Block> {
        for (i, raw) in self.lines.iter().enumerate() {
            let (key, value) = split_key_value(raw.trim());
            if key != "host" { continue; }
            let al = aliases(&value);
            if !al.iter().any(|a| a == alias) { continue; }
            let mut end = i + 1;
            while end < self.lines.len() {
                let (k, _) = split_key_value(self.lines[end].trim());
                if k == "host" || k == "match" { break; }
                end += 1;
            }
            // Хвостовые пустые строки и мета следующего блока к этому хосту не относятся.
            while end > i + 1 {
                let t = self.lines[end - 1].trim();
                if t.is_empty() || parse_meta(t).is_some() { end -= 1 } else { break }
            }
            let mut start = i;
            if i > 0 && parse_meta(self.lines[i - 1].trim()).is_some() { start = i - 1; }
            return Some(Block { start: start as u32, end: end as u32, host_line: i as u32, is_shared: al.len() > 1 });
        }
        None
    }

    pub fn current_lines(&self, alias: &str) -> Vec<String> {
        self.block(alias).map(|b| self.lines[b.start as usize..b.end as usize].to_vec()).unwrap_or_default()
    }

    /// Строки блока после сохранения `host`; незнакомые директивы старого блока сохраняются.
    pub fn rendered_lines(&self, host: &SshHost, original_alias: Option<&str>) -> Vec<String> {
        self.rendered_lines_for(host, original_alias, ConfigPlatform::Macos)
    }

    /// Строки блока для `platform`: значения с пробелами — в кавычках, UseKeychain — только для macOS.
    pub fn rendered_lines_for(&self, host: &SshHost, original_alias: Option<&str>, platform: ConfigPlatform) -> Vec<String> {
        let mut out = Vec::new();
        out.extend(meta_line(host.group.as_deref(), &host.tags, host.color.as_deref(), host.os, host.tmux, &[]));

        out.push(format!("Host {}", host.alias));
        let mut add = |k: &str, v: Option<String>| {
            if let Some(v) = v.filter(|v| !v.is_empty()) { out.push(format!("    {k} {}", quote_value(&v))); }
        };
        add("HostName", host.host_name.clone());
        add("User", host.user.clone());
        add("Port", host.port.map(|p| p.to_string()));
        let keys: Vec<String> = if host.identity_files.is_empty() { host.identity_file.clone().into_iter().collect() }
                                else { host.identity_files.clone() };
        for k in &keys { add("IdentityFile", Some(k.clone())); }
        let old_body: Vec<String> = original_alias.and_then(|a| self.block(a))
            .map(|b| self.lines[(b.host_line as usize + 1)..b.end as usize].to_vec()).unwrap_or_default();
        let has = |name: &str| old_body.iter().any(|l| { let t = l.trim(); !t.starts_with('#') && split_key_value(t).0 == name });
        if keys.iter().any(|k| !k.is_empty()) {
            if platform == ConfigPlatform::Macos && !has("usekeychain") { add("UseKeychain", Some("yes".into())); }
            if !has("addkeystoagent") { add("AddKeysToAgent", Some("yes".into())); }
        }
        add("ProxyJump", host.proxy_jump.clone());
        // Явный выбор в редакторе (bool) важнее сырого значения из конфига; без выбора остаётся как в конфиге.
        let tri = |raw: &Option<String>, flag: Option<bool>| flag.map(|b| if b { "yes" } else { "no" }.to_string()).or_else(|| raw.clone());
        add("ForwardAgent", tri(&host.forward_agent_value, host.forward_agent));
        add("ServerAliveInterval", host.server_alive_interval.map(|p| p.to_string()));
        add("Compression", tri(&host.compression_value, host.compression));

        for raw in &old_body {
            let t = raw.trim();
            if t.is_empty() { continue; }
            let (key, _) = split_key_value(t);
            if t.starts_with('#') || !MANAGED.contains(&key.as_str()) { out.push(raw.clone()); }
        }
        out
    }

    /// Добавить хост (`original_alias == None`) или заменить блок существующего.
    pub fn upsert(&mut self, host: &SshHost, original_alias: Option<&str>) -> Result<(), CoreError> {
        self.upsert_for(host, original_alias, ConfigPlatform::Macos)
    }

    pub fn upsert_for(&mut self, host: &SshHost, original_alias: Option<&str>, platform: ConfigPlatform) -> Result<(), CoreError> {
        check_host(host)?;
        if Some(host.alias.as_str()) != original_alias && self.block(&host.alias).is_some() {
            return Err(CoreError::AliasTaken(host.alias.clone()));
        }
        let rendered = self.rendered_lines_for(host, original_alias, platform);
        match original_alias {
            Some(orig) => {
                let b = self.block(orig).ok_or_else(|| CoreError::NotFound(orig.to_string()))?;
                if b.is_shared { return Err(CoreError::SharedBlock(orig.to_string())); }
                self.lines.splice(b.start as usize..b.end as usize, rendered);
            }
            None => {
                if self.lines.last().map(|l| !l.trim().is_empty()).unwrap_or(false) { self.lines.push(String::new()); }
                self.lines.extend(rendered);
            }
        }
        Ok(())
    }

    pub fn remove(&mut self, alias: &str) -> Result<(), CoreError> {
        let b = self.block(alias).ok_or_else(|| CoreError::NotFound(alias.to_string()))?;
        if b.is_shared { return Err(CoreError::SharedBlock(alias.to_string())); }
        let mut end = b.end as usize;
        // И пустая строка-разделитель после блока.
        if end < self.lines.len() && self.lines[end].trim().is_empty() { end += 1; }
        self.lines.drain(b.start as usize..end);
        Ok(())
    }

    /// Заменить блок готовыми строками или добавить в конец (синхронизация).
    pub fn replace_or_append(&mut self, alias: &str, block: Vec<String>) {
        match self.block(alias) {
            Some(b) => { self.lines.splice(b.start as usize..b.end as usize, block); }
            None => {
                if self.lines.last().map(|l| !l.trim().is_empty()).unwrap_or(false) { self.lines.push(String::new()); }
                self.lines.extend(block);
            }
        }
    }
}

// MARK: - API для клиентов (функции над текстом)

/// Поменять только строку `# relaya:` над блоком `alias`; сам блок и незнакомые ключи метаданных не трогаются.
/// Нет метаданных — строка убирается. Общий блок `Host a b` разрешён: метаданные у блока одни.
#[uniffi::export]
pub fn config_set_meta(text: String, alias: String, group: Option<String>, tags: Vec<String>, color: Option<String>,
                       os: Option<ServerOs>, tmux: bool) -> Result<String, CoreError> {
    for v in group.iter().chain(color.iter()).chain(tags.iter()) {
        if v.contains(['\n', '\r']) { return Err(CoreError::InvalidValue(v.clone())); }
    }
    let mut d = Document::new(&text);
    let b = d.block(&alias).ok_or_else(|| CoreError::NotFound(alias.clone()))?;
    let (start, host_line) = (b.start as usize, b.host_line as usize);
    let extra: Vec<String> = if start < host_line {
        let body = d.lines[start].trim().trim_start_matches('#').trim();
        meta_tokens(&body["relaya:".len()..]).into_iter()
            .filter(|p| p.split_once('=').map(|(k, _)| !META_KEYS.contains(&k.to_lowercase().as_str())).unwrap_or(true))
            .map(|p| match p.split_once('=') { Some((k, v)) => format!("{k}={}", meta_value(v)), None => p })
            .collect()
    } else { Vec::new() };
    let line = meta_line(group.as_deref(), &tags, color.as_deref(), os, tmux, &extra);
    d.lines.splice(start..host_line, line);
    Ok(d.text())
}

#[uniffi::export]
pub fn config_block(text: String, alias: String) -> Option<Block> { Document::new(&text).block(&alias) }

#[uniffi::export]
pub fn config_current_lines(text: String, alias: String) -> Vec<String> { Document::new(&text).current_lines(&alias) }

#[uniffi::export]
pub fn config_rendered_lines(text: String, host: SshHost, original_alias: Option<String>) -> Vec<String> {
    Document::new(&text).rendered_lines(&host, original_alias.as_deref())
}

/// То же, что `config_rendered_lines`, но с проверкой значений и для своей платформы.
#[uniffi::export]
pub fn config_rendered_lines_checked(text: String, host: SshHost, original_alias: Option<String>, platform: ConfigPlatform)
    -> Result<Vec<String>, CoreError> {
    check_host(&host)?;
    Ok(Document::new(&text).rendered_lines_for(&host, original_alias.as_deref(), platform))
}

/// `config_upsert` для платформы: на Windows и Linux новые блоки без UseKeychain.
#[uniffi::export]
pub fn config_upsert_for(text: String, host: SshHost, original_alias: Option<String>, platform: ConfigPlatform) -> Result<String, CoreError> {
    let mut d = Document::new(&text);
    d.upsert_for(&host, original_alias.as_deref(), platform)?;
    Ok(d.text())
}

/// Конфиг с Mac для ssh на Windows/Linux: если где-то есть UseKeychain, в начало встаёт `IgnoreUnknown UseKeychain`
/// (или UseKeychain дописывается в уже стоящий глобальный IgnoreUnknown). Иначе ssh отказывается читать конфиг.
#[uniffi::export]
pub fn config_for_platform(text: String, platform: ConfigPlatform) -> String {
    if platform == ConfigPlatform::Macos { return text; }
    let mut d = Document::new(&text);
    let directive = |l: &str| { let t = l.trim(); if t.starts_with('#') { String::new() } else { split_key_value(t).0 } };
    if !d.lines.iter().any(|l| directive(l) == "usekeychain") { return text; }
    let global_end = d.lines.iter().position(|l| matches!(directive(l).as_str(), "host" | "match")).unwrap_or(d.lines.len());
    match d.lines[..global_end].iter().position(|l| directive(l) == "ignoreunknown") {
        Some(i) => {
            let (_, v) = split_key_value(d.lines[i].trim());
            if v.split(',').any(|x| x.trim().eq_ignore_ascii_case("usekeychain")) { return text; }
            let indent: String = d.lines[i].chars().take_while(|c| c.is_whitespace()).collect();
            d.lines[i] = format!("{indent}IgnoreUnknown {v},UseKeychain");
        }
        None => d.lines.insert(0, "IgnoreUnknown UseKeychain".into()),
    }
    d.text()
}

#[uniffi::export]
pub fn config_upsert(text: String, host: SshHost, original_alias: Option<String>) -> Result<String, CoreError> {
    let mut d = Document::new(&text);
    d.upsert(&host, original_alias.as_deref())?;
    Ok(d.text())
}

#[uniffi::export]
pub fn config_remove(text: String, alias: String) -> Result<String, CoreError> {
    let mut d = Document::new(&text);
    d.remove(&alias)?;
    Ok(d.text())
}

#[uniffi::export]
pub fn config_lines(text: String) -> Vec<String> { Document::new(&text).lines }

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "# relaya: group=\"мои сервера\" tags=prod,db color=orange os=ubuntu tmux=on\nHost web web-alias\n    HostName 10.0.0.1\n    User deploy\n    Port 2222\n    Port 3333\n\nHost *\n    ServerAliveInterval 30\n\nMatch host x\n    User nobody\n\nHost db\n    HostName=db.example\n    ForwardAgent yes\n";

    #[test]
    fn parses_hosts_meta_and_first_wins() {
        let h = parse_config(SAMPLE.into());
        assert_eq!(h.iter().map(|h| h.alias.as_str()).collect::<Vec<_>>(), ["web", "web-alias", "db"]);
        assert_eq!(h[0].group.as_deref(), Some("мои сервера"));
        assert_eq!(h[0].tags, ["prod", "db"]);
        assert_eq!(h[0].os, Some(ServerOs::Ubuntu));
        assert!(h[0].tmux);
        assert_eq!(h[0].port, Some(2222));
        assert_eq!(h[2].host_name.as_deref(), Some("db.example"));
        assert_eq!(h[2].forward_agent, Some(true));
        assert_eq!(h[2].group, None);
        assert_eq!(h[0].subtitle(), "deploy@10.0.0.1:2222");
    }

    #[test]
    fn upsert_keeps_unknown_directives_and_meta() {
        let text = "Host web\n    HostName old\n    LocalForward 8080 localhost:80\n";
        let mut host = SshHost::new("web");
        host.host_name = Some("new".into());
        host.tags = vec!["prod".into()];
        let out = config_upsert(text.into(), host, Some("web".into())).unwrap();
        assert!(out.contains("# relaya: tags=prod\nHost web\n    HostName new"));
        assert!(out.contains("LocalForward 8080 localhost:80"));
        assert!(!out.contains("old"));
    }

    #[test]
    fn add_remove_and_errors() {
        let mut d = Document::new("Host a\n    HostName a\n");
        d.upsert(&SshHost::new("b"), None).unwrap();
        assert_eq!(d.text(), "Host a\n    HostName a\n\nHost b\n");
        assert_eq!(d.upsert(&SshHost::new("a"), None), Err(CoreError::AliasTaken("a".into())));
        d.remove("a").unwrap();
        assert_eq!(d.text(), "Host b\n");
        let shared = Document::new("Host x y\n");
        let mut s2 = shared.clone();
        assert_eq!(s2.remove("x"), Err(CoreError::SharedBlock("x".into())));
    }

    #[test]
    fn git_service_and_tags() {
        let mut h = SshHost::new("gh");
        h.host_name = Some("github.com".into());
        assert!(h.is_git_service());
        assert!(SshHost::new("git@git.lan.mftkhv.ru").is_git_service());
        let mut h2 = SshHost::new("lan");
        h2.host_name = Some("git@git.lan".into());
        assert!(h2.is_git_service());
        assert!(!SshHost::new("web").is_git_service());
        assert_eq!(split_tags("prod, db,,Prod".into()), ["prod", "db"]);
    }

    #[test]
    fn parses_destinations() {
        let d = |u: Option<&str>, h: &str, p: Option<i64>| Destination { user: u.map(Into::into), host: h.into(), port: p };
        assert_eq!(parse_destination("git@a.b".into()), d(Some("git"), "a.b", None));
        assert_eq!(parse_destination("a.b".into()), d(None, "a.b", None));
        assert_eq!(parse_destination("root@1.2.3.4:2222".into()), d(Some("root"), "1.2.3.4", Some(2222)));
        assert_eq!(parse_destination("[::1]:22".into()), d(None, "::1", Some(22)));
        assert_eq!(parse_destination("me@[fe80::1]".into()), d(Some("me"), "fe80::1", None));
        assert_eq!(parse_destination("fe80::1".into()), d(None, "fe80::1", None));
        assert_eq!(parse_destination("  git@ git.lan.mftkhv.ru  ".into()), d(Some("git"), "git.lan.mftkhv.ru", None));
        assert_eq!(parse_destination("ssh://u@h:22/".into()), d(Some("u"), "h", Some(22)));
        assert_eq!(parse_destination("@h:99999".into()), d(None, "h:99999", None));
        assert_eq!(parse_destination("".into()), d(None, "", None));
    }

    #[test]
    fn trailing_comments_are_not_values() {
        let h = parse_config("Host web # production\n    HostName x.example # note\n    IdentityFile \"~/.ssh/a #1\"\n    User a#b\n".into());
        assert_eq!(h.len(), 1);
        assert_eq!(h[0].alias, "web");
        assert_eq!(h[0].host_name.as_deref(), Some("x.example"));
        assert_eq!(h[0].identity_file.as_deref(), Some("~/.ssh/a #1"));
        assert_eq!(h[0].user.as_deref(), Some("a#b"));
        assert!(!Document::new("Host web # production\n").block("web").unwrap().is_shared);
    }

    #[test]
    fn set_meta_touches_only_the_meta_line() {
        let cfg = "Host a\n    User x\n\n# relaya: group=old future=\"k v\" tmux=on\nHost b c\n    HostName b.example\n";
        let out = config_set_meta(cfg.into(), "c".into(), Some("мои сервера".into()), vec!["prod".into(), "db".into()],
                                  Some("orange".into()), None, false).unwrap();
        assert_eq!(out, "Host a\n    User x\n\n# relaya: group=\"мои сервера\" tags=prod,db color=orange future=\"k v\"\nHost b c\n    HostName b.example\n");
        let added = config_set_meta(cfg.into(), "a".into(), None, vec![], None, None, true).unwrap();
        assert!(added.starts_with("# relaya: tmux=on\nHost a\n    User x\n\n# relaya: group=old"), "{added}");
        let cleared = config_set_meta("# relaya: tags=x\nHost a\n    User x\n".into(), "a".into(), None, vec![], None, None, false).unwrap();
        assert_eq!(cleared, "Host a\n    User x\n");
        assert_eq!(config_set_meta(cfg.into(), "zz".into(), None, vec![], None, None, false), Err(CoreError::NotFound("zz".into())));
        assert!(matches!(config_set_meta(cfg.into(), "a".into(), Some("x\nHost evil".into()), vec![], None, None, false), Err(CoreError::InvalidValue(_))));
    }

    #[test]
    fn c1_tristate_lists_quotes_and_line_breaks() {
        let text = "Host web\n    HostName old\n    IdentityFile ~/.ssh/a\n    IdentityFile \"~/.ssh/my key\"\n    ForwardAgent no\n    UseKeychain no\n    AddKeysToAgent confirm\n";
        let h = parse_config(text.into()).remove(0);
        assert_eq!(h.identity_files, vec!["~/.ssh/a", "~/.ssh/my key"]);
        assert_eq!(h.identity_file.as_deref(), Some("~/.ssh/a"));
        assert_eq!(h.forward_agent_value.as_deref(), Some("no"));
        assert_eq!(h.compression_value, None);
        let out = config_upsert(text.into(), h.clone(), Some("web".into())).unwrap();
        assert_eq!(out, "Host web\n    HostName old\n    IdentityFile ~/.ssh/a\n    IdentityFile \"~/.ssh/my key\"\n    ForwardAgent no\n    UseKeychain no\n    AddKeysToAgent confirm\n");
        let mut bad = h.clone();
        bad.user = Some("x\nProxyCommand evil".into());
        assert!(matches!(config_upsert(text.into(), bad.clone(), Some("web".into())), Err(CoreError::InvalidValue(_))));
        assert!(matches!(config_rendered_lines_checked(text.into(), bad, None, ConfigPlatform::Macos), Err(CoreError::InvalidValue(_))));
        // Старые поля без новых — как раньше; на Windows без UseKeychain.
        let mut n = SshHost::new("n");
        n.identity_file = Some("C:\\Users\\My Name\\.ssh\\id".into());
        n.forward_agent = Some(true);
        assert_eq!(config_upsert("".into(), n.clone(), None).unwrap(),
                   "Host n\n    IdentityFile \"C:\\Users\\My Name\\.ssh\\id\"\n    UseKeychain yes\n    AddKeysToAgent yes\n    ForwardAgent yes\n");
        assert_eq!(config_upsert_for("".into(), n, None, ConfigPlatform::Windows).unwrap(),
                   "Host n\n    IdentityFile \"C:\\Users\\My Name\\.ssh\\id\"\n    AddKeysToAgent yes\n    ForwardAgent yes\n");
    }

    #[test]
    fn explicit_flag_beats_raw_value() {
        let text = "Host a\n    ForwardAgent no\n    Compression yes\n";
        let mut h = parse_config(text.into()).remove(0);
        h.forward_agent = Some(true);
        h.compression = None;
        let out = config_upsert(text.into(), h, Some("a".into())).unwrap();
        assert!(out.contains("ForwardAgent yes") && out.contains("Compression yes"), "{out}");
        let mut off = parse_config(text.into()).remove(0);
        off.forward_agent = None;
        off.forward_agent_value = None;
        assert!(!config_upsert(text.into(), off, Some("a".into())).unwrap().contains("ForwardAgent"));
    }

    #[test]
    fn config_for_platform_adds_ignore_unknown() {
        let mac = "Host a\n    UseKeychain yes\n";
        assert_eq!(config_for_platform(mac.into(), ConfigPlatform::Macos), mac);
        assert_eq!(config_for_platform(mac.into(), ConfigPlatform::Windows), "IgnoreUnknown UseKeychain\nHost a\n    UseKeychain yes\n");
        assert_eq!(config_for_platform("IgnoreUnknown AddKeysToAgent\n\nHost a\n    UseKeychain yes\n".into(), ConfigPlatform::Linux),
                   "IgnoreUnknown AddKeysToAgent,UseKeychain\n\nHost a\n    UseKeychain yes\n");
        let done = config_for_platform(mac.into(), ConfigPlatform::Linux);
        assert_eq!(config_for_platform(done.clone(), ConfigPlatform::Linux), done);
        assert_eq!(config_for_platform("Host a\n".into(), ConfigPlatform::Windows), "Host a\n");
    }

    /// Конфиг с Mac проходит `ssh -G` на этой машине (в CI — windows-latest и ubuntu). Без ssh тест пропускается.
    #[test]
    fn mac_config_passes_ssh_g_here() {
        if cfg!(target_os = "macos") { return; }
        let platform = if cfg!(windows) { ConfigPlatform::Windows } else { ConfigPlatform::Linux };
        let mut h = SshHost::new("web");
        h.host_name = Some("10.0.0.1".into());
        h.identity_file = Some("~/.ssh/id_ed25519".into());
        let mac = config_upsert("".into(), h, None).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("config");
        std::fs::write(&file, config_for_platform(mac.clone(), platform)).unwrap();
        let Ok(out) = std::process::Command::new("ssh").arg("-G").arg("-F").arg(&file).arg("web").output() else { return };
        assert!(out.status.success(), "ssh -G: {}", String::from_utf8_lossy(&out.stderr));
        assert!(String::from_utf8_lossy(&out.stdout).to_lowercase().contains("hostname 10.0.0.1"));
        // И без IgnoreUnknown ssh действительно падает — тест проверяет то, что нужно.
        std::fs::write(&file, mac).unwrap();
        let raw = std::process::Command::new("ssh").arg("-G").arg("-F").arg(&file).arg("web").output().unwrap();
        assert!(!raw.status.success());
    }
}
