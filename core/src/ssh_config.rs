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
        self.user.as_deref() == Some("git") || KNOWN.contains(&name.as_str())
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

/// `Key value`, `Key=value`, `Key = "value"` → (ключ в нижнем регистре, значение).
pub(crate) fn split_key_value(line: &str) -> (String, String) {
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

fn apply(key: &str, value: &str, host: &mut SshHost) {
    // В ssh_config побеждает первое значение.
    match key {
        "hostname" if host.host_name.is_none() => host.host_name = Some(value.to_string()),
        "user" if host.user.is_none() => host.user = Some(value.to_string()),
        "port" if host.port.is_none() => host.port = value.parse().ok(),
        "identityfile" if host.identity_file.is_none() => host.identity_file = Some(value.to_string()),
        "proxyjump" if host.proxy_jump.is_none() => host.proxy_jump = Some(value.to_string()),
        "forwardagent" if host.forward_agent.is_none() => host.forward_agent = Some(value.eq_ignore_ascii_case("yes")),
        "serveraliveinterval" if host.server_alive_interval.is_none() => host.server_alive_interval = value.parse().ok(),
        "compression" if host.compression.is_none() => host.compression = Some(value.eq_ignore_ascii_case("yes")),
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
const MANAGED: &[&str] = &["hostname", "user", "port", "identityfile", "proxyjump", "forwardagent",
                             "serveraliveinterval", "compression", "usekeychain", "addkeystoagent"];

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
        let mut out = Vec::new();
        let mut meta = Vec::new();
        if let Some(g) = host.group.as_deref().filter(|g| !g.is_empty()) { meta.push(format!("group={}", meta_value(g))); }
        let tags = split_tags(host.tags.join(","));
        if !tags.is_empty() { meta.push(format!("tags={}", meta_value(&tags.join(",")))); }
        if let Some(c) = host.color.as_deref().filter(|c| !c.is_empty()) { meta.push(format!("color={c}")); }
        if let Some(os) = host.os { meta.push(format!("os={}", os.raw())); }
        if host.tmux { meta.push("tmux=on".into()); }
        if !meta.is_empty() { out.push(format!("# relaya: {}", meta.join(" "))); }

        out.push(format!("Host {}", host.alias));
        let mut add = |k: &str, v: Option<String>| {
            if let Some(v) = v.filter(|v| !v.is_empty()) { out.push(format!("    {k} {v}")); }
        };
        add("HostName", host.host_name.clone());
        add("User", host.user.clone());
        add("Port", host.port.map(|p| p.to_string()));
        add("IdentityFile", host.identity_file.clone());
        if host.identity_file.as_deref().map(|s| !s.is_empty()).unwrap_or(false) {
            add("UseKeychain", Some("yes".into()));
            add("AddKeysToAgent", Some("yes".into()));
        }
        add("ProxyJump", host.proxy_jump.clone());
        if host.forward_agent == Some(true) { add("ForwardAgent", Some("yes".into())); }
        add("ServerAliveInterval", host.server_alive_interval.map(|p| p.to_string()));
        if host.compression == Some(true) { add("Compression", Some("yes".into())); }

        if let Some(b) = original_alias.and_then(|a| self.block(a)) {
            for raw in &self.lines[(b.host_line as usize + 1)..b.end as usize] {
                let t = raw.trim();
                if t.is_empty() { continue; }
                let (key, _) = split_key_value(t);
                if t.starts_with('#') || !MANAGED.contains(&key.as_str()) { out.push(raw.clone()); }
            }
        }
        out
    }

    /// Добавить хост (`original_alias == None`) или заменить блок существующего.
    pub fn upsert(&mut self, host: &SshHost, original_alias: Option<&str>) -> Result<(), CoreError> {
        if Some(host.alias.as_str()) != original_alias && self.block(&host.alias).is_some() {
            return Err(CoreError::AliasTaken(host.alias.clone()));
        }
        let rendered = self.rendered_lines(host, original_alias);
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

#[uniffi::export]
pub fn config_block(text: String, alias: String) -> Option<Block> { Document::new(&text).block(&alias) }

#[uniffi::export]
pub fn config_current_lines(text: String, alias: String) -> Vec<String> { Document::new(&text).current_lines(&alias) }

#[uniffi::export]
pub fn config_rendered_lines(text: String, host: SshHost, original_alias: Option<String>) -> Vec<String> {
    Document::new(&text).rendered_lines(&host, original_alias.as_deref())
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
        assert_eq!(split_tags("prod, db,,Prod".into()), ["prod", "db"]);
    }
}
