//! Какие хосты ходят с ключом: `IdentityFile <ключ>` + `IdentitiesOnly yes` в их блоках ~/.ssh/config.
//! Видны и правятся все блоки, включая git-серверы (gitlab.com, свой Forgejo) и общие `Host a b`.
//! Только этот ключ (IdentitiesOnly) — иначе ssh-agent перебирает все ключи и сервер рвёт вход.

use crate::ssh_config::{is_pattern, parse_destination, Document};

fn key_of(line: &str) -> (String, String) {
    let t = line.trim();
    let mut it = t.splitn(2, |c: char| c.is_whitespace() || c == '=');
    let k = it.next().unwrap_or("").to_lowercase();
    let v = it.next().unwrap_or("").trim().trim_start_matches('=').trim().trim_matches('"').to_string();
    (k, v)
}

/// `~/.ssh/id_ed25519`, `/Users/me/.ssh/id_ed25519`, `C:\Users\me\.ssh\id_ed25519` → `id_ed25519` (имя внутри .ssh).
fn norm(path: &str) -> String {
    let p = path.trim().trim_matches('"').replace('\\', "/");
    match p.rfind("/.ssh/") { Some(i) => p[i + 6..].to_string(), None => p.trim_start_matches("~/").to_string() }
}

/// Путь с пробелами (`C:\Users\My Name\.ssh\id`) ssh читает только в кавычках.
fn quoted(path: &str) -> String { if path.contains(char::is_whitespace) { format!("\"{path}\"") } else { path.to_string() } }

fn host_aliases(value: &str) -> Vec<String> { value.split_whitespace().map(str::to_string).collect() }

/// Все конкретные хосты конфига (без шаблонов) — для выбора, включая git-серверы.
#[uniffi::export]
pub fn config_all_aliases(text: String) -> Vec<String> {
    let mut out = Vec::new();
    for l in text.lines() {
        let (k, v) = key_of(l);
        if k == "host" { for a in host_aliases(&v) { if !is_pattern(a.clone()) && !out.contains(&a) { out.push(a); } } }
    }
    out
}

/// Хосты, в блоках которых IdentityFile — этот ключ.
#[uniffi::export]
pub fn config_key_hosts(text: String, key: String) -> Vec<String> {
    let want = norm(&key);
    let mut out = Vec::new();
    let mut current: Vec<String> = Vec::new();
    for l in text.lines() {
        let (k, v) = key_of(l);
        match k.as_str() {
            "host" => current = host_aliases(&v).into_iter().filter(|a| !is_pattern(a.clone())).collect(),
            "match" => current.clear(),
            "identityfile" if norm(&v) == want => for a in &current { if !out.contains(a) { out.push(a.clone()); } },
            _ => {}
        }
    }
    out
}

/// Назначить ключ ровно этим хостам: добавить/заменить IdentityFile + IdentitiesOnly yes, у снятых — убрать.
/// Хоста нет в конфиге — появится короткий блок. Общий блок `Host a b` разделяется, только если выбраны не все его имена.
#[uniffi::export]
pub fn config_bind_key(text: String, key: String, hosts: Vec<String>) -> String {
    let mut doc = Document::new(&text);
    // `git@host` без своего блока — это хост `host` с `User git`.
    let mut users: Vec<(String, Option<String>, Option<i64>)> = Vec::new();
    let hosts: Vec<String> = hosts.into_iter().map(|a| {
        if doc.block(&a).is_some() { return a; }
        let d = parse_destination(a.clone());
        if d.host.is_empty() { return a; }
        users.push((d.host.clone(), d.user, d.port));
        d.host
    }).collect();
    let before = config_key_hosts(text, key.clone());
    for a in before.iter().filter(|a| !hosts.contains(a)) {
        split_if_shared(&mut doc, a, &[]);
        set_key(&mut doc, a, None, &key);
    }
    for a in &hosts {
        if doc.block(a).is_none() {
            if doc.lines.last().map(|l| !l.trim().is_empty()).unwrap_or(false) { doc.lines.push(String::new()); }
            // Блок «Добавить сервер» — для git-сервера: пользователь из `user@`, иначе git.
            let (user, port) = users.iter().find(|u| &u.0 == a).map(|u| (u.1.clone(), u.2)).unwrap_or((None, None));
            doc.lines.extend([format!("Host {a}"), format!("    IdentityFile {}", quoted(&key)), "    IdentitiesOnly yes".into(),
                              format!("    User {}", user.unwrap_or_else(|| "git".into()))]);
            if let Some(p) = port { doc.lines.push(format!("    Port {p}")); }
            continue;
        }
        split_if_shared(&mut doc, a, &hosts);
        set_key(&mut doc, a, Some(&key), &key);
    }
    doc.text()
}

/// Если `alias` в общем блоке и не все его имена в `keep_together` — вынести его в свой блок с теми же настройками.
fn split_if_shared(doc: &mut Document, alias: &str, keep_together: &[String]) {
    let Some(b) = doc.block(alias) else { return };
    if !b.is_shared { return; }
    let (_, value) = key_of(&doc.lines[b.host_line as usize]);
    let names = host_aliases(&value);
    if names.iter().all(|n| keep_together.contains(n)) { return; }
    let indent: String = doc.lines[b.host_line as usize].chars().take_while(|c| c.is_whitespace()).collect();
    let rest: Vec<String> = names.iter().filter(|n| n.as_str() != alias).cloned().collect();
    doc.lines[b.host_line as usize] = format!("{indent}Host {}", rest.join(" "));
    let body: Vec<String> = doc.lines[b.host_line as usize + 1..b.end as usize].to_vec();
    let mut block = vec![String::new(), format!("Host {alias}")];
    block.extend(body);
    doc.lines.splice(b.end as usize..b.end as usize, block);
}

/// Поставить (Some) или снять (None, только если стоит именно `key`) ключ в блоке своего хоста.
fn set_key(doc: &mut Document, alias: &str, new: Option<&str>, key: &str) {
    let Some(b) = doc.block(alias) else { return };
    let (start, end) = (b.host_line as usize + 1, b.end as usize);
    let had_this = doc.lines[start..end].iter().any(|l| { let (k, v) = key_of(l); k == "identityfile" && norm(&v) == norm(key) });
    if new.is_none() && !had_this { return; }
    let indent = doc.lines[start..end].iter().find(|l| !l.trim().is_empty() && !l.trim().starts_with('#'))
        .map(|l| l.chars().take_while(|c| c.is_whitespace()).collect::<String>()).unwrap_or_else(|| "    ".into());
    let mut body: Vec<String> = doc.lines[start..end].iter()
        .filter(|l| { let (k, _) = key_of(l); k != "identityfile" && k != "identitiesonly" }).cloned().collect();
    if let Some(k) = new { body.splice(0..0, [format!("{indent}IdentityFile {}", quoted(k)), format!("{indent}IdentitiesOnly yes")]); }
    let empty = body.iter().all(|l| l.trim().is_empty() || l.trim().starts_with('#'));
    if empty && new.is_none() {
        // Блок держался только на ключе — убрать целиком (с `# relaya:` и пустой строкой после).
        let mut e = end;
        let mut s = b.start as usize;
        if e < doc.lines.len() && doc.lines[e].trim().is_empty() { e += 1; }
        else if e == doc.lines.len() && s > 0 && doc.lines[s - 1].trim().is_empty() { s -= 1; }
        doc.lines.drain(s..e);
    } else {
        doc.lines.splice(start..end, body);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONFIG: &str = "Host gitlab.farcana.com git.lan.example\n    User git\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n\nHost web\n    HostName 10.0.0.1\n    User root\n";

    #[test]
    fn lists_hosts_of_a_key() {
        assert_eq!(config_key_hosts(CONFIG.into(), "/Users/me/.ssh/id_ed25519".into()), vec!["gitlab.farcana.com", "git.lan.example"]);
        assert_eq!(config_all_aliases(CONFIG.into()), vec!["gitlab.farcana.com", "git.lan.example", "web"]);
    }

    #[test]
    fn binds_new_and_existing_hosts() {
        let out = config_bind_key(CONFIG.into(), "~/.ssh/id_ed25519".into(),
            vec!["gitlab.farcana.com".into(), "git.lan.example".into(), "web".into(), "github.com".into()]);
        assert!(out.contains("Host gitlab.farcana.com git.lan.example\n"), "{out}");
        assert!(out.contains("Host web\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n    HostName 10.0.0.1"), "{out}");
        assert!(out.contains("Host github.com\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n    User git"), "{out}");
    }

    #[test]
    fn unbinding_splits_shared_block_and_drops_empty_blocks() {
        let out = config_bind_key(CONFIG.into(), "~/.ssh/id_ed25519".into(), vec!["gitlab.farcana.com".into()]);
        assert!(out.contains("Host gitlab.farcana.com\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n    User git"), "{out}");
        assert!(out.contains("Host git.lan.example\n    User git\n"), "{out}");
        assert!(!out.contains("Host git.lan.example\n    User git\n    IdentityFile"), "{out}");
        let gone = config_bind_key("Host a\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n\nHost b\n    User x\n".into(), "~/.ssh/k".into(), vec![]);
        assert_eq!(gone, "Host b\n    User x\n");
    }

    #[test]
    fn match_blocks_are_neither_listed_nor_touched() {
        let cfg = "Host web\n    User root\n\nMatch host web exec \"true\"\n    IdentityFile ~/.ssh/k\n";
        assert!(config_key_hosts(cfg.into(), "~/.ssh/k".into()).is_empty());
        let out = config_bind_key(cfg.into(), "~/.ssh/k".into(), vec!["web".into()]);
        assert_eq!(out, "Host web\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n    User root\n\nMatch host web exec \"true\"\n    IdentityFile ~/.ssh/k\n");
        assert_eq!(config_bind_key(out, "~/.ssh/k".into(), vec![]), cfg);
    }

    #[test]
    fn include_lines_stay_and_included_hosts_get_own_block() {
        let cfg = "Include ~/.ssh/config.d/*\n\nHost web\n    Include extra.conf\n    User root\n";
        let out = config_bind_key(cfg.into(), "~/.ssh/k".into(), vec!["web".into(), "fromfile".into()]);
        assert_eq!(out, "Include ~/.ssh/config.d/*\n\nHost web\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n    Include extra.conf\n    User root\n\nHost fromfile\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n    User git\n");
    }

    #[test]
    fn comments_are_kept_and_commented_keys_ignored() {
        let cfg = "Host web\n    # IdentityFile ~/.ssh/k\n    User root # prod\n";
        assert!(config_key_hosts(cfg.into(), "~/.ssh/k".into()).is_empty());
        let out = config_bind_key(cfg.into(), "~/.ssh/k".into(), vec!["web".into()]);
        assert_eq!(out, "Host web\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n    # IdentityFile ~/.ssh/k\n    User root # prod\n");
        assert_eq!(config_bind_key(out, "~/.ssh/k".into(), vec![]), cfg);
    }

    #[test]
    fn quoted_and_equals_identity_files_match() {
        let cfg = "Host a\n    IdentityFile \"~/.ssh/k\"\nHost b\n    IdentityFile=~/.ssh/k\nHost c\n    identityfile = \"/Users/me/.ssh/k\"\n";
        assert_eq!(config_key_hosts(cfg.into(), "~/.ssh/k".into()), vec!["a", "b", "c"]);
        assert_eq!(config_bind_key(cfg.into(), "~/.ssh/k".into(), vec![]), "");
    }

    #[test]
    fn windows_paths_match_and_spaces_get_quoted() {
        let cfg = "Host a\n    IdentityFile C:\\Users\\me\\.ssh\\k\n";
        assert_eq!(config_key_hosts(cfg.into(), "~/.ssh/k".into()), vec!["a"]);
        let key = "C:\\Users\\My Name\\.ssh\\k";
        let out = config_bind_key("Host b\n    User x\n".into(), key.into(), vec!["b".into(), "c".into()]);
        assert_eq!(out, "Host b\n    IdentityFile \"C:\\Users\\My Name\\.ssh\\k\"\n    IdentitiesOnly yes\n    User x\n\nHost c\n    IdentityFile \"C:\\Users\\My Name\\.ssh\\k\"\n    IdentitiesOnly yes\n    User git\n");
        assert_eq!(config_key_hosts(out.clone(), key.into()), vec!["b", "c"]);
        // Блок, созданный под git-сервер, после снятия ключа остаётся с `User git` — его настройки не теряем.
        assert_eq!(config_bind_key(out, key.into(), vec![]), "Host b\n    User x\n\nHost c\n    User git\n");
    }

    #[test]
    fn new_blocks_are_git_servers_and_user_at_is_split() {
        let out = config_bind_key("Host web\n    User root\n".into(), "~/.ssh/k".into(),
            vec!["git@git.lan.mftkhv.ru".into(), "deploy@code.example:2222".into(), "plain.example".into()]);
        assert_eq!(out, "Host web\n    User root\n\nHost git.lan.mftkhv.ru\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n    User git\n\nHost code.example\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n    User deploy\n    Port 2222\n\nHost plain.example\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n    User git\n");
        assert_eq!(config_key_hosts(out.clone(), "~/.ssh/k".into()), vec!["git.lan.mftkhv.ru", "code.example", "plain.example"]);
        // `git@host` при уже существующем блоке `host` — правится он, а старая кривая запись `Host git@…` — как есть.
        let again = config_bind_key(out.clone(), "~/.ssh/k".into(), vec!["git@git.lan.mftkhv.ru".into(), "code.example".into(), "plain.example".into()]);
        assert_eq!(again, out);
        let legacy = "Host git@x\n    IdentityFile ~/.ssh/k\n";
        assert_eq!(config_bind_key(legacy.into(), "~/.ssh/k".into(), vec!["git@x".into()]), "Host git@x\n    IdentityFile ~/.ssh/k\n    IdentitiesOnly yes\n");
    }
}
