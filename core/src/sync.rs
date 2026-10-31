//! Личная синхронизация по профилям: git-репозиторий пользователя или папка iCloud Drive.
//! Слияние без удалений; пароли не синхронизируются; ключи — по выбору, только хостов профиля и зашифрованные.
//! Ключи шифруются так же, как в Swift-версии (PBKDF2-SHA256 → ChaCha20-Poly1305, формат RLYK1) — файлы взаимозаменяемы.

use crate::error::CoreError;
use crate::models::{encode_sorted, try_decode_list, RemoteDesktop, Snippet, Tunnel};
use crate::ssh_config::{parse_config, split_key_value, aliases, Document};
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum SyncItem { SshConfig, Snippets, Tunnels, Desktops, Agents, Keys }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum SyncBackend { Git, ICloud }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct SyncScope {
    pub all_hosts: bool,
    pub groups: Vec<String>,
    pub hosts: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SyncProfile {
    pub id: String,
    pub name: String,
    pub backend: SyncBackend,
    pub remote: String,
    pub scope: SyncScope,
    pub items: Vec<SyncItem>,
    pub auto: bool,
    pub enabled: bool,
}

impl SyncProfile {
    /// Сниппеты и права агентов не привязаны к хостам — только для профиля «все хосты».
    pub fn effective_items(&self) -> HashSet<SyncItem> {
        self.items.iter().copied().filter(|i| self.scope.all_hosts || !matches!(i, SyncItem::Snippets | SyncItem::Agents)).collect()
    }
    fn contains(&self, h: &crate::ssh_config::SshHost) -> bool {
        self.scope.all_hosts || self.scope.hosts.contains(&h.alias) || h.group.as_ref().map(|g| self.scope.groups.contains(g)).unwrap_or(false)
    }
}

#[uniffi::export]
pub fn sync_new_profile(name: String) -> SyncProfile {
    SyncProfile { id: crate::models::new_id(), name, backend: SyncBackend::Git, remote: String::new(),
                  scope: SyncScope { all_hosts: true, groups: vec![], hosts: vec![] },
                  items: vec![SyncItem::SshConfig, SyncItem::Snippets, SyncItem::Tunnels, SyncItem::Desktops], auto: true, enabled: true }
}

/// Где лежат локальные файлы: папка `~/.ssh` и папка данных приложения.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncPaths { pub ssh: String, pub support: String }

impl SyncPaths {
    fn config(&self) -> PathBuf { Path::new(&self.ssh).join("config") }
    fn support(&self, f: &str) -> PathBuf { Path::new(&self.support).join(f) }
}

fn read(p: &Path) -> Option<Vec<u8>> { fs::read(p).ok() }

fn write_if_changed(dir: &Path, rel: &str, data: &[u8], changed: &mut Vec<String>) -> Result<(), CoreError> {
    let dest = dir.join(rel);
    if read(&dest).as_deref() == Some(data) { return Ok(()); }
    if let Some(parent) = dest.parent() { fs::create_dir_all(parent)?; }
    fs::write(&dest, data)?;
    changed.push(rel.into());
    Ok(())
}

// MARK: - Блоки ~/.ssh/config

/// Только блоки нужных хостов (с `# relaya:`), в порядке файла.
#[uniffi::export]
pub fn config_extract(text: String, aliases_in: Vec<String>) -> String {
    let doc = Document::new(&text);
    let mut sorted = aliases_in.clone();
    sorted.sort();
    let mut taken: Vec<(u32, u32, u32)> = Vec::new();
    for a in sorted {
        if let Some(b) = doc.block(&a) { if !taken.iter().any(|t| t.0 == b.start) { taken.push((b.start, b.host_line, b.end)); } }
    }
    taken.sort();
    // Из общего блока `Host a b` уходят только выбранные имена: невыбранное не должно попасть в общий файл.
    let blocks: Vec<String> = taken.iter().map(|&(s, h, e)| {
        let mut lines = doc.lines[s as usize..e as usize].to_vec();
        let (_, v) = split_key_value(doc.lines[h as usize].trim());
        let names = aliases(&v);
        let chosen: Vec<&String> = names.iter().filter(|n| aliases_in.contains(n)).collect();
        if chosen.len() < names.len() {
            let indent: String = doc.lines[h as usize].chars().take_while(|c| c.is_whitespace()).collect();
            lines[(h - s) as usize] = format!("{indent}Host {}", chosen.iter().map(|n| n.as_str()).collect::<Vec<_>>().join(" "));
        }
        lines.join("\n")
    }).collect();
    if blocks.is_empty() { String::new() } else { blocks.join("\n\n") + "\n" }
}

/// Убрать `alias` из локального конфига: из общего блока — только имя, свой блок — целиком.
/// Возвращает место, куда встаёт пришедший блок, и вырезанный диапазон (start, len), если строки удалены.
fn take_alias(doc: &mut Document, alias: &str) -> Option<(usize, Option<(usize, usize)>)> {
    let b = doc.block(alias)?;
    let (s, h, e) = (b.start as usize, b.host_line as usize, b.end as usize);
    if b.is_shared {
        let (_, v) = split_key_value(doc.lines[h].trim());
        let rest: Vec<String> = aliases(&v).into_iter().filter(|n| n != alias).collect();
        let indent: String = doc.lines[h].chars().take_while(|c| c.is_whitespace()).collect();
        doc.lines[h] = format!("{indent}Host {}", rest.join(" "));
        Some((e, None))
    } else {
        doc.lines.drain(s..e);
        Some((s, Some((s, e - s))))
    }
}

/// Пришедшие блоки заменяют одноимённые, новые — в конец; остальной файл не меняется.
/// Общие блоки не теряют чужих имён: `Host a` из папки вырезает `a` из локального `Host a b`, а не весь блок.
#[uniffi::export]
pub fn config_merge(local: String, incoming: String) -> String {
    let mut doc = Document::new(&local);
    let source = Document::new(&incoming);
    let mut seen = HashSet::new();
    let mut cut_any = false;
    for h in parse_config(incoming.clone()) {
        if seen.contains(&h.alias) { continue; }
        let Some(b) = source.block(&h.alias) else { continue };
        let block = source.lines[b.start as usize..b.end as usize].to_vec();
        let (_, v) = split_key_value(source.lines[b.host_line as usize].trim());
        let names = aliases(&v);
        let mut pos: Option<usize> = None;
        for a in &names {
            seen.insert(a.clone());
            while let Some((p, cut)) = take_alias(&mut doc, a) {
                if cut.is_some() { cut_any = true; }
                if let (Some(cur), Some((start, len))) = (pos.as_mut(), cut) { if start < *cur { *cur -= len.min(*cur - start); } }
                pos.get_or_insert(p);
            }
        }
        match pos {
            Some(p) => {
                let mut ins = block;
                if p > 0 && !doc.lines[p - 1].trim().is_empty() { ins.insert(0, String::new()); }
                if p < doc.lines.len() && !doc.lines[p].trim().is_empty() { ins.push(String::new()); }
                doc.lines.splice(p..p, ins);
            }
            None => doc.replace_or_append(&h.alias, block),
        }
    }
    // Вырезанный последним блок оставляет пустую строку-разделитель в конце.
    while cut_any && doc.lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) { doc.lines.pop(); }
    doc.text()
}

// MARK: - Выгрузка и загрузка

/// Записать в `dir` то, что относится к профилю. Возвращает изменённые пути.
/// Удалённое на этой машине с прошлой синхронизации уходит из общих файлов и попадает в `relaya/deleted.json`.
#[uniffi::export]
pub fn sync_export(profile: SyncProfile, paths: SyncPaths, passphrase: Option<String>, dir: String) -> Result<Vec<String>, CoreError> {
    let local = local_items(&profile, &paths)?;
    let mut tombs = tombstones::prepare(&profile, &paths, Path::new(&dir), &local)?;
    let mut changed = export_inner(profile.clone(), paths.clone(), passphrase, dir.clone())?;
    tombstones::strip_shared(Path::new(&dir), &mut tombs, &mut changed)?;
    // Похороненное остаётся в снимке до импорта: если слияние сорвётся, удаление не потеряется.
    tombstones::save_snapshot(&profile, &paths, &local, &tombs)?;
    Ok(changed)
}

fn export_inner(profile: SyncProfile, paths: SyncPaths, passphrase: Option<String>, dir: String) -> Result<Vec<String>, CoreError> {
    let dir = Path::new(&dir);
    let items = profile.effective_items();
    let mut changed = Vec::new();
    let config_text = fs::read_to_string(paths.config()).unwrap_or_default();
    let hosts: Vec<_> = parse_config(config_text.clone()).into_iter().filter(|h| profile.contains(h) && !h.is_git_service()).collect();
    let aliases_set: HashSet<String> = hosts.iter().map(|h| h.alias.clone()).collect();

    // Своё добавляется к тому, что уже в папке, а не заменяет её: Mac без хостов не должен обнулить общий файл.
    if items.contains(&SyncItem::SshConfig) {
        let existing = fs::read_to_string(dir.join("ssh/config")).unwrap_or_default();
        let mine = config_extract(config_text, aliases_set.iter().cloned().collect());
        let merged = if existing.trim().is_empty() { mine } else { config_merge(existing, mine) };
        write_if_changed(dir, "ssh/config", merged.as_bytes(), &mut changed)?;
    }
    if items.contains(&SyncItem::Snippets) {
        if let Ok(j) = fs::read_to_string(paths.support("snippets.json")) {
            let mut list = merged_with_existing(dir, "relaya/snippets.json", try_decode_list::<Snippet>(&j).map_err(|e| broken("snippets.json", e))?, |x| x.id.clone())?;
            list.sort_by(|a, b| a.id.cmp(&b.id));
            write_if_changed(dir, "relaya/snippets.json", encode_sorted(&list).as_bytes(), &mut changed)?;
        }
    }
    if items.contains(&SyncItem::Tunnels) {
        if let Ok(j) = fs::read_to_string(paths.support("tunnels.json")) {
            let mine: Vec<Tunnel> = try_decode_list::<Tunnel>(&j).map_err(|e| broken("tunnels.json", e))?.into_iter().filter(|t| aliases_set.contains(&t.host_alias)).collect();
            let mut list = merged_with_existing(dir, "relaya/tunnels.json", mine, |x| x.id.clone())?;
            list.sort_by(|a, b| a.id.cmp(&b.id));
            write_if_changed(dir, "relaya/tunnels.json", encode_sorted(&list).as_bytes(), &mut changed)?;
        }
    }
    if items.contains(&SyncItem::Desktops) {
        if let Ok(j) = fs::read_to_string(paths.support("desktops.json")) {
            let mine: Vec<RemoteDesktop> = try_decode_list::<RemoteDesktop>(&j).map_err(|e| broken("desktops.json", e))?.into_iter().filter(|d| {
                profile.scope.all_hosts || d.group.as_ref().map(|g| profile.scope.groups.contains(g)).unwrap_or(false)
                    || d.via_ssh_host.as_ref().map(|v| aliases_set.contains(v)).unwrap_or(false)
            }).collect();
            let mut list = merged_with_existing(dir, "relaya/desktops.json", mine, |x| x.id.clone())?;
            list.sort_by(|a, b| a.id.cmp(&b.id));
            write_if_changed(dir, "relaya/desktops.json", encode_sorted(&list).as_bytes(), &mut changed)?;
        }
    }
    if items.contains(&SyncItem::Agents) {
        if let Some(d) = read(&paths.support("mcp.json")) { write_if_changed(dir, "relaya/mcp.json", &d, &mut changed)?; }
    }
    if let (true, Some(pass)) = (items.contains(&SyncItem::Keys), passphrase) {
        // `~` раскрывается через папку .ssh из SyncPaths (на Windows HOME обычно не задан), разделители и регистр — как у Windows.
        let used: HashSet<String> = hosts.iter().flat_map(|h| {
            if h.identity_files.is_empty() { h.identity_file.clone().into_iter().collect() } else { h.identity_files.clone() }
        }).map(|p| key_path_norm(&paths.ssh, &p)).collect();
        changed.extend(keys_export(&paths.ssh, &pass, Some(&used), dir)?);
    }
    Ok(changed)
}

/// Список в папке + свои элементы (свои заменяют одноимённые по id): выгрузка ничего не удаляет из общего.
fn merged_with_existing<T>(dir: &Path, rel: &str, mine: Vec<T>, id: impl Fn(&T) -> String) -> Result<Vec<T>, CoreError>
where T: for<'de> Deserialize<'de> + Clone {
    let mut out: Vec<T> = match fs::read_to_string(dir.join(rel)) {
        Ok(s) => try_decode_list(&s).map_err(|e| broken(rel, e))?,
        Err(_) => Vec::new(),
    };
    for item in mine {
        match out.iter().position(|o| id(o) == id(&item)) { Some(i) => out[i] = item, None => out.push(item) }
    }
    Ok(out)
}

/// Файл не читается: синхронизация останавливается и ничего не перезаписывает.
fn broken(name: &str, e: CoreError) -> CoreError { CoreError::Json(format!("{name} повреждён, синхронизация остановлена: {e}")) }

/// Влить в локальные файлы содержимое `dir`. Возвращает изменившиеся пункты.
/// Надгробия из `relaya/deleted.json` удаляют локальные элементы, которые не правились с прошлой синхронизации.
#[uniffi::export]
pub fn sync_import(profile: SyncProfile, paths: SyncPaths, passphrase: Option<String>, dir: String) -> Result<Vec<SyncItem>, CoreError> {
    let mut changed = import_inner(profile.clone(), paths.clone(), passphrase, dir.clone())?;
    for item in tombstones::apply_locally(&profile, &paths, Path::new(&dir))? { if !changed.contains(&item) { changed.push(item); } }
    tombstones::save_snapshot(&profile, &paths, &local_items(&profile, &paths)?, &[])?;
    Ok(changed)
}

fn import_inner(profile: SyncProfile, paths: SyncPaths, passphrase: Option<String>, dir: String) -> Result<Vec<SyncItem>, CoreError> {
    let dir = Path::new(&dir);
    let items = profile.effective_items();
    let mut changed = Vec::new();

    if items.contains(&SyncItem::SshConfig) {
        if let Ok(incoming) = fs::read_to_string(dir.join("ssh/config")) {
            // Профиль «группа work» не должен приносить чужие хосты из общего файла.
            let incoming = if profile.scope.all_hosts { incoming } else {
                let wanted: Vec<String> = parse_config(incoming.clone()).into_iter()
                    .filter(|h| profile.contains(h) && !h.is_git_service()).map(|h| h.alias).collect();
                config_extract(incoming, wanted)
            };
            let local = fs::read_to_string(paths.config()).unwrap_or_default();
            // UseKeychain с Mac ломает ssh на Windows и Linux — там конфиг получает IgnoreUnknown.
            let merged = crate::ssh_config::config_for_platform(config_merge(local.clone(), incoming), crate::ssh_config::ConfigPlatform::current());
            if merged != local {
                fs::create_dir_all(&paths.ssh)?;
                // Без копии конфиг не меняем: ошибка бэкапа прерывает импорт.
                if paths.config().exists() {
                    let bak = Path::new(&paths.ssh).join("config.bak");
                    fs::copy(paths.config(), &bak).map_err(|e| CoreError::Io(format!("config.bak: {e}")))?;
                    set_private(&bak);
                }
                write_private_atomic(&paths.config(), merged.as_bytes())?;
                changed.push(SyncItem::SshConfig);
            }
        }
    }
    if items.contains(&SyncItem::Snippets) && merge_list_where::<Snippet>(&dir.join("relaya/snippets.json"), &paths.support("snippets.json"), |x| x.id.clone(), |_| true)? {
        changed.push(SyncItem::Snippets);
    }
    // Хосты профиля по общему файлу: туннели и рабочие столы чужих хостов не приходят.
    let scoped: HashSet<String> = fs::read_to_string(dir.join("ssh/config")).map(|t| parse_config(t).into_iter()
        .filter(|h| profile.contains(h)).map(|h| h.alias).collect()).unwrap_or_default();
    let all = profile.scope.all_hosts;
    if items.contains(&SyncItem::Tunnels) && merge_list_where::<Tunnel>(&dir.join("relaya/tunnels.json"), &paths.support("tunnels.json"), |x| x.id.clone(),
        |t| all || scoped.contains(&t.host_alias))? {
        changed.push(SyncItem::Tunnels);
    }
    if items.contains(&SyncItem::Desktops) && merge_list_where::<RemoteDesktop>(&dir.join("relaya/desktops.json"), &paths.support("desktops.json"), |x| x.id.clone(),
        |d| all || d.group.as_ref().map(|g| profile.scope.groups.contains(g)).unwrap_or(false)
            || d.via_ssh_host.as_ref().map(|v| scoped.contains(v)).unwrap_or(false))? {
        changed.push(SyncItem::Desktops);
    }
    if items.contains(&SyncItem::Agents) {
        if let Some(d) = read(&dir.join("relaya/mcp.json")) {
            if read(&paths.support("mcp.json")).as_deref() != Some(d.as_slice()) {
                fs::create_dir_all(&paths.support)?;
                fs::write(paths.support("mcp.json"), d)?;
                changed.push(SyncItem::Agents);
            }
        }
    }
    if let (true, Some(pass)) = (items.contains(&SyncItem::Keys), passphrase) {
        // Только ключи, которыми пользуются хосты профиля (по имени файла внутри .ssh).
        let only: Option<HashSet<String>> = (!all).then(|| fs::read_to_string(dir.join("ssh/config")).map(|t| parse_config(t).into_iter()
            .filter(|h| scoped.contains(&h.alias)).flat_map(|h| h.identity_files.into_iter())
            .filter_map(|p| p.replace('\\', "/").rsplit('/').next().map(str::to_string)).collect()).unwrap_or_default());
        let (added, renamed) = keys_import(&paths.ssh, &pass, dir, only.as_ref())?;
        if !added.is_empty() { changed.push(SyncItem::Keys); }
        if !renamed.is_empty() { remember_renamed(&paths, renamed); }
    }
    Ok(changed)
}

/// Пришедшие элементы заменяют свои по id, новые добавляются, остальные остаются.
fn merge_list_where<T>(incoming: &Path, local: &Path, id: impl Fn(&T) -> String, keep: impl Fn(&T) -> bool) -> Result<bool, CoreError>
where T: Serialize + for<'de> Deserialize<'de> + PartialEq + Clone {
    let Ok(j) = fs::read_to_string(incoming) else { return Ok(false) };
    let name = incoming.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let theirs: Vec<T> = try_decode_list::<T>(&j).map_err(|e| broken(&format!("{name} в папке синхронизации"), e))?
        .into_iter().filter(|x| keep(x)).collect();
    let mut mine: Vec<T> = match fs::read_to_string(local) {
        Ok(s) => match try_decode_list(&s) {
            Ok(v) => v,
            Err(e) => {
                // Свой файл не читается — копия рядом, сам файл не трогаем.
                let _ = fs::copy(local, local.with_extension("json.bak"));
                return Err(broken(&name, e));
            }
        },
        Err(_) => Vec::new(),
    };
    let mut changed = false;
    for item in theirs {
        match mine.iter().position(|m| id(m) == id(&item)) {
            Some(i) => if mine[i] != item { mine[i] = item; changed = true },
            None => { mine.push(item); changed = true }
        }
    }
    if changed {
        if let Some(p) = local.parent() { fs::create_dir_all(p)?; }
        fs::write(local, encode_sorted(&mine))?;
    }
    Ok(changed)
}
/// Временный файл рядом → права 0600 → rename: ssh никогда не прочтёт половину конфига, а ключ не будет открыт.
fn write_private_atomic(dest: &Path, data: &[u8]) -> Result<(), CoreError> {
    let tmp = dest.with_file_name(format!(".{}.relaya-tmp", dest.file_name().map(|n| n.to_string_lossy()).unwrap_or_default()));
    fs::write(&tmp, data)?;
    set_private(&tmp);
    if let Err(e) = fs::rename(&tmp, dest) { let _ = fs::remove_file(&tmp); return Err(e.into()); }
    Ok(())
}

#[cfg(unix)]
fn set_private(p: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(p, fs::Permissions::from_mode(0o600));
}
#[cfg(not(unix))]
fn set_private(_p: &Path) {}

// MARK: - Ключи

const MAGIC: &[u8] = b"RLYK1";
const MIN_ROUNDS: u32 = 10_000;
const MAX_ROUNDS: u32 = 5_000_000;

fn derive(pass: &str, salt: &[u8], rounds: u32) -> Key {
    let mut out = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<sha2::Sha256>(pass.as_bytes(), salt, rounds, &mut out);
    *Key::from_slice(&out)
}

/// RLYK1 · соль 16 · итерации (u32 BE) · nonce 12 · шифртекст+тег.
#[uniffi::export]
pub fn key_encrypt(data: Vec<u8>, passphrase: String, rounds: u32) -> Vec<u8> {
    use rand::RngCore;
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut salt);
    rand::thread_rng().fill_bytes(&mut nonce);
    let cipher = ChaCha20Poly1305::new(&derive(&passphrase, &salt, rounds));
    let sealed = cipher.encrypt(Nonce::from_slice(&nonce), data.as_slice()).expect("encrypt");
    [MAGIC, &salt, &rounds.to_be_bytes(), &nonce, &sealed].concat()
}

#[uniffi::export]
pub fn key_decrypt(blob: Vec<u8>, passphrase: String) -> Result<Vec<u8>, CoreError> {
    if blob.len() <= 5 + 16 + 4 + 28 || &blob[..5] != MAGIC { return Err(CoreError::Decrypt); }
    let salt = &blob[5..21];
    let rounds = u32::from_be_bytes(blob[21..25].try_into().unwrap());
    // Число итераций берётся из файла: без границ чужой файл подвесил бы расшифровку (или ослабил ключ).
    if !(MIN_ROUNDS..=MAX_ROUNDS).contains(&rounds) { return Err(CoreError::Decrypt); }
    let cipher = ChaCha20Poly1305::new(&derive(&passphrase, salt, rounds));
    cipher.decrypt(Nonce::from_slice(&blob[25..37]), &blob[37..]).map_err(|_| CoreError::Decrypt)
}

/// Путь ключа для сравнения: `~/.ssh/x` и `~\\.ssh\\x` → `<ssh>/x`, `\\` → `/`, на Windows без учёта регистра.
fn key_path_norm(ssh: &str, p: &str) -> String {
    let p = p.trim().trim_matches('"').replace('\\', "/");
    let ssh = ssh.replace('\\', "/").trim_end_matches('/').to_string();
    let full = if let Some(rest) = p.strip_prefix("~/.ssh/") { format!("{ssh}/{rest}") }
        else if let Some(rest) = p.strip_prefix("~/") { format!("{}/{rest}", ssh.rsplit_once('/').map(|x| x.0).unwrap_or("")) }
        else { p };
    if cfg!(windows) { full.to_lowercase() } else { full }
}

fn keys_export(ssh: &str, pass: &str, only: Option<&HashSet<String>>, dir: &Path) -> Result<Vec<String>, CoreError> {
    let keys_dir = dir.join("keys");
    let mut changed = Vec::new();
    let Ok(entries) = fs::read_dir(ssh) else { return Ok(changed) };
    let mut names: Vec<String> = entries.filter_map(|e| e.ok()?.file_name().into_string().ok()).filter(|n| n.ends_with(".pub")).collect();
    names.sort();
    for name in names {
        let base = name.trim_end_matches(".pub").to_string();
        let private = Path::new(ssh).join(&base);
        if let Some(only) = only { if !only.contains(&key_path_norm(ssh, &private.to_string_lossy())) { continue; } }
        let Some(key) = read(&private) else { continue };
        fs::create_dir_all(&keys_dir)?;
        let out = keys_dir.join(format!("{base}.relaya-key"));
        if let Some(existing) = read(&out) { if key_decrypt(existing, pass.into()).ok().as_deref() == Some(key.as_slice()) { continue; } }
        fs::write(&out, key_encrypt(key, pass.into(), 600_000))?;
        fs::copy(Path::new(ssh).join(&name), keys_dir.join(&name))?;
        changed.push(format!("keys/{base}"));
    }
    Ok(changed)
}

/// Ключ из синхронизации не встал под своим именем: там уже лежит другой ключ.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct RenamedKey { pub name: String, pub saved_as: String }

fn keys_import(ssh: &str, pass: &str, dir: &Path, only: Option<&HashSet<String>>) -> Result<(Vec<String>, Vec<RenamedKey>), CoreError> {
    let keys_dir = dir.join("keys");
    let (mut added, mut renamed) = (Vec::new(), Vec::new());
    let Ok(entries) = fs::read_dir(&keys_dir) else { return Ok((added, renamed)) };
    let mut names: Vec<String> = entries.filter_map(|e| e.ok()?.file_name().into_string().ok()).filter(|n| n.ends_with(".relaya-key")).collect();
    names.sort();
    for name in names {
        let base = name.trim_end_matches(".relaya-key").to_string();
        if let Some(only) = only { if !only.contains(&base) { continue; } }
        let key = key_decrypt(fs::read(keys_dir.join(&name))?, pass.into())?;
        let mut target = base.clone();
        let dest_of = |t: &str| Path::new(ssh).join(t);
        if let Some(existing) = read(&dest_of(&target)) {
            if existing == key { continue; }
            // Одноимённый, но другой ключ: свой не трогаем, пришедший кладём рядом и сообщаем клиенту.
            target = format!("{base}.from-sync");
            let mut n = 2;
            while let Some(e) = read(&dest_of(&target)) { if e == key { break; } target = format!("{base}.from-sync-{n}"); n += 1; }
            if read(&dest_of(&target)).as_deref() == Some(key.as_slice()) { continue; }
            renamed.push(RenamedKey { name: base.clone(), saved_as: target.clone() });
        }
        fs::create_dir_all(ssh)?;
        write_private_atomic(&dest_of(&target), &key)?;
        if let Some(p) = read(&keys_dir.join(format!("{base}.pub"))) { let _ = fs::write(Path::new(ssh).join(format!("{target}.pub")), p); }
        added.push(target);
    }
    Ok((added, renamed))
}

fn warnings_file(paths: &SyncPaths) -> PathBuf { paths.support("sync-warnings.json") }

fn remember_renamed(paths: &SyncPaths, mut renamed: Vec<RenamedKey>) {
    let mut all: Vec<RenamedKey> = fs::read_to_string(warnings_file(paths)).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    all.append(&mut renamed);
    let _ = fs::create_dir_all(&paths.support);
    let _ = fs::write(warnings_file(paths), encode_sorted(&all));
}

/// Ключи, переименованные при импорте с прошлого вызова (git_sync, folder_sync_merge, sync_import), — показать
/// пользователю один раз: `id_ed25519` из синхронизации лежит как `id_ed25519.from-sync`.
#[uniffi::export]
pub fn sync_take_renamed_keys(paths: SyncPaths) -> Vec<RenamedKey> {
    let list = fs::read_to_string(warnings_file(&paths)).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let _ = fs::remove_file(warnings_file(&paths));
    list
}

// MARK: - Git

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncConflict { pub path: String, pub mine: String, pub theirs: String }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SyncOutcome {
    UpToDate,
    Synced { pulled: bool, imported: Vec<SyncItem> },
    Conflict { conflicts: Vec<SyncConflict> },
}

const BRANCH: &str = "main";

/// Ошибка git: весь значимый вывод (ssh пишет причину не в последней строке) — клиенты объясняют его через ssh_explain
/// на языке интерфейса.
fn git_error(text: &str) -> String {
    let t = text.trim();
    if t.is_empty() { "git".into() } else { t.to_string() }
}

struct Git { repo: PathBuf }

impl Git {
    fn run(&self, args: &[&str], allow_failure: bool) -> Result<std::process::Output, CoreError> {
        let out = crate::command("git")
            .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-C"]).arg(&self.repo).args(args)
            .env("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=15").env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_AUTHOR_NAME", "Relaya").env("GIT_AUTHOR_EMAIL", "relaya@localhost")
            .env("GIT_COMMITTER_NAME", "Relaya").env("GIT_COMMITTER_EMAIL", "relaya@localhost")
            .output().map_err(|e| CoreError::Git(format!("git: {e}")))?;
        if !out.status.success() && !allow_failure {
            let text = format!("{}{}", String::from_utf8_lossy(&out.stderr), String::from_utf8_lossy(&out.stdout));
            return Err(CoreError::Git(git_error(&text)));
        }
        Ok(out)
    }
    fn ok(&self, args: &[&str]) -> bool { self.run(args, true).map(|o| o.status.success()).unwrap_or(false) }
    fn stdout(&self, args: &[&str]) -> Result<String, CoreError> { Ok(String::from_utf8_lossy(&self.run(args, false)?.stdout).into_owned()) }
    fn remote_has_branch(&self) -> bool { self.ok(&["rev-parse", "--verify", "-q", &format!("origin/{BRANCH}")]) }
    fn in_merge(&self) -> bool { self.repo.join(".git/MERGE_HEAD").exists() }

    fn set_up(&self, remote: &str) -> Result<(), CoreError> {
        if self.repo.join(".git").exists() {
            self.run(&["remote", "set-url", "origin", remote], false)?;
            return Ok(());
        }
        let _ = fs::remove_dir_all(&self.repo);
        fs::create_dir_all(&self.repo)?;
        let r = (|| {
            self.run(&["init", "-q", "-b", BRANCH], false)?;
            self.run(&["remote", "add", "origin", remote], false)?;
            self.run(&["fetch", "-q", "origin"], false)?;
            if self.remote_has_branch() { self.run(&["reset", "-q", "--hard", &format!("origin/{BRANCH}")], false)?; }
            Ok(())
        })();
        // Неудачный первый fetch не должен оставить .git со своим корнем — повтор начнёт с нуля.
        if r.is_err() { let _ = fs::remove_dir_all(&self.repo); }
        r
    }

    fn head(&self) -> Option<String> { self.stdout(&["rev-parse", "HEAD"]).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) }
    fn marker(&self) -> PathBuf { self.repo.join(".git").join("relaya-imported") }

    /// Разнести репозиторий по локальным файлам, если с последнего удачного импорта HEAD другой:
    /// первый запуск (reset на origin) и упавший прошлый импорт тоже импортируются.
    fn import_if_new(&self, profile: SyncProfile, paths: SyncPaths, passphrase: Option<String>) -> Result<Vec<SyncItem>, CoreError> {
        let Some(head) = self.head() else { return Ok(vec![]) };
        if fs::read_to_string(self.marker()).ok().map(|m| m.trim() == head).unwrap_or(false) { return Ok(vec![]); }
        let keys_pending = profile.effective_items().contains(&SyncItem::Keys) && passphrase.is_none();
        let imported = sync_import(profile, paths, passphrase, self.repo.to_string_lossy().into_owned())?;
        // Ключи без пароля синхронизации пропущены — импорт повторится, когда пароль появится.
        if !keys_pending { let _ = fs::write(self.marker(), &head); }
        Ok(imported)
    }

    fn conflicts(&self) -> Result<Vec<SyncConflict>, CoreError> {
        let names = self.stdout(&["diff", "--name-only", "--diff-filter=U"])?;
        Ok(names.lines().filter(|l| !l.is_empty()).map(|p| SyncConflict {
            path: p.into(),
            mine: self.run(&["show", &format!(":2:{p}")], true).map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default(),
            theirs: self.run(&["show", &format!(":3:{p}")], true).map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default(),
        }).collect())
    }
}

/// Один цикл для профиля: выгрузка → коммит → забрать с сервера (слияние) → разнести пришедшее → отправить.
/// Работает синхронно (запускает git) — клиенты вызывают его не из главного потока.
#[uniffi::export]
pub fn git_sync(repo: String, remote: String, machine: String, profile: SyncProfile, paths: SyncPaths,
                passphrase: Option<String>) -> Result<SyncOutcome, CoreError> {
    let git = Git { repo: PathBuf::from(&repo) };
    git.set_up(remote.trim())?;
    if git.in_merge() { return Ok(SyncOutcome::Conflict { conflicts: git.conflicts()? }); }
    sync_export(profile.clone(), paths.clone(), passphrase.clone(), repo.clone())?;
    git.run(&["add", "-A"], false)?;
    let dirty = !git.stdout(&["status", "--porcelain"])?.trim().is_empty();
    if dirty { git.run(&["commit", "-q", "-m", &format!("Relaya: {machine}")], false)?; }
    git.run(&["fetch", "-q", "origin"], false)?;
    let mut pulled = false;
    if git.remote_has_branch() {
        let head = git.stdout(&["rev-parse", "HEAD"]).unwrap_or_default();
        let mut merge = git.run(&["merge", "-q", "--no-edit", &format!("origin/{BRANCH}")], true)?;
        if !merge.status.success() && String::from_utf8_lossy(&merge.stderr).contains("unrelated histories") {
            merge = git.run(&["merge", "-q", "--no-edit", "--allow-unrelated-histories", &format!("origin/{BRANCH}")], true)?;
        }
        if !merge.status.success() {
            let mut c = git.conflicts()?;
            let mut resolved = false;
            // deleted.json сливается сам: надгробия двух машин объединяются, конфликт пользователю не нужен.
            if let Some(i) = c.iter().position(|x| x.path == tombstones::FILE) {
                let merged = tombstones::merge_text(&c[i].mine, &c[i].theirs);
                fs::write(Path::new(&repo).join(tombstones::FILE), merged)?;
                git.run(&["add", "--", tombstones::FILE], false)?;
                c.remove(i);
                if c.is_empty() { git.run(&["commit", "-q", "--no-edit"], false)?; resolved = true; }
            }
            if !c.is_empty() { return Ok(SyncOutcome::Conflict { conflicts: c }); }
            if !resolved { return Err(CoreError::Git(String::from_utf8_lossy(&merge.stderr).trim().to_string())); }
        }
        pulled = git.stdout(&["rev-parse", "HEAD"]).unwrap_or_default() != head;
    }
    let imported = git.import_if_new(profile, paths, passphrase)?;
    let ahead = git.run(&["rev-list", "--count", &format!("origin/{BRANCH}..HEAD")], true)
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<i64>().unwrap_or(1)).unwrap_or(1);
    let needs_push = !git.remote_has_branch() || ahead > 0;
    if needs_push && git.ok(&["rev-parse", "--verify", "-q", "HEAD"]) { git.run(&["push", "-q", "origin", &format!("HEAD:{BRANCH}")], false)?; }
    Ok(if dirty || pulled || needs_push || !imported.is_empty() { SyncOutcome::Synced { pulled, imported } } else { SyncOutcome::UpToDate })
}

/// Разрешить конфликт (`keep_mine` по пути), закоммитить, разнести и отправить.
#[uniffi::export]
pub fn git_resolve(repo: String, keep_mine: std::collections::HashMap<String, bool>, profile: SyncProfile, paths: SyncPaths,
                   passphrase: Option<String>) -> Result<Vec<SyncItem>, CoreError> {
    let git = Git { repo: PathBuf::from(&repo) };
    for (path, mine) in &keep_mine {
        git.run(&["checkout", if *mine { "--ours" } else { "--theirs" }, "--", path], false)?;
        git.run(&["add", "--", path], false)?;
    }
    git.run(&["commit", "-q", "--no-edit"], false)?;
    let imported = git.import_if_new(profile, paths, passphrase)?;
    git.run(&["push", "-q", "origin", &format!("HEAD:{BRANCH}")], false)?;
    Ok(imported)
}

/// Отказаться от слияния: ничего не меняется ни здесь, ни на сервере.
#[uniffi::export]
pub fn git_abort_merge(repo: String) {
    let _ = Git { repo: PathBuf::from(repo) }.run(&["merge", "--abort"], true);
}

/// Папка (iCloud Drive): сначала влить пришедшее, потом выгрузить своё.
#[uniffi::export]
pub fn folder_sync(profile: SyncProfile, paths: SyncPaths, passphrase: Option<String>, folder: String) -> Result<Vec<SyncItem>, CoreError> {
    fs::create_dir_all(&folder)?;
    let imported = sync_import(profile.clone(), paths.clone(), passphrase.clone(), folder.clone())?;
    sync_export(profile, paths, passphrase, folder)?;
    Ok(imported)
}

// MARK: - Папка «как в git»

/// Все файлы папки (кроме скрытых, `.icloud`-заглушек и `.git`) — относительные пути через `/`.
fn tree(dir: &Path) -> std::collections::BTreeMap<String, Vec<u8>> {
    fn walk(root: &Path, dir: &Path, out: &mut std::collections::BTreeMap<String, Vec<u8>>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') { continue; }
            let p = e.path();
            if p.is_dir() { walk(root, &p, out); continue; }
            if let (Ok(rel), Ok(data)) = (p.strip_prefix(root), fs::read(&p)) {
                out.insert(rel.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/"), data);
            }
        }
    }
    let mut out = Default::default();
    walk(dir, dir, &mut out);
    out
}

/// Записать через временный файл и rename: облачная папка не увидит половину файла.
fn write_atomic(dest: &Path, data: &[u8]) -> Result<(), CoreError> {
    if let Some(parent) = dest.parent() { fs::create_dir_all(parent)?; }
    let tmp = dest.with_file_name(format!(".{}.relaya-tmp", dest.file_name().map(|n| n.to_string_lossy()).unwrap_or_default()));
    fs::write(&tmp, data)?;
    fs::rename(&tmp, dest)?;
    Ok(())
}

fn put_tree(dir: &Path, files: &std::collections::BTreeMap<String, Vec<u8>>) -> Result<(), CoreError> {
    for (rel, data) in files {
        let dest = dir.join(rel);
        if read(&dest).as_deref() != Some(data.as_slice()) { write_atomic(&dest, data)?; }
    }
    Ok(())
}

/// Папка (iCloud Drive, общая папка) с трёхсторонним слиянием, как в git.
/// База — снимок папки после прошлой удачной синхронизации (в `support/sync/<id профиля>/base`).
/// Своё = база + выгрузка этой машины, чужое = папка сейчас. Изменилась одна сторона — берётся она;
/// обе и по-разному — конфликт в той же форме, что у `git_sync`. Повторный вызов с `keep_mine` по путям
/// разрешает конфликты (true — своё, false — из папки); пока конфликт не разрешён, ничего не пишется.
#[uniffi::export]
pub fn folder_sync_merge(profile: SyncProfile, paths: SyncPaths, passphrase: Option<String>, folder: String,
                         keep_mine: std::collections::HashMap<String, bool>) -> Result<SyncOutcome, CoreError> {
    let folder_p = Path::new(&folder);
    fs::create_dir_all(folder_p)?;
    let state = Path::new(&paths.support).join("sync").join(&profile.id);
    let base_dir = state.join("base");
    let theirs = tree(folder_p);
    // Первая синхронизация: базой считается папка, своё ложится поверх неё (как reset на origin в git).
    let base = if base_dir.exists() { tree(&base_dir) } else { theirs.clone() };

    let stage = state.join("stage");
    let _ = fs::remove_dir_all(&stage);
    fs::create_dir_all(&stage)?;
    put_tree(&stage, &base)?;
    // Надгробия из папки видны выгрузке сразу: свежая правка воскрешает удалённое другой машиной.
    if let Some(t) = theirs.get(tombstones::FILE) {
        let b = base.get(tombstones::FILE).map(|d| String::from_utf8_lossy(d).into_owned()).unwrap_or_default();
        write_atomic(&stage.join(tombstones::FILE), tombstones::merge_text(&b, &String::from_utf8_lossy(t)).as_bytes())?;
    }
    sync_export(profile.clone(), paths.clone(), passphrase.clone(), stage.to_string_lossy().into_owned())?;
    let mine = tree(&stage);
    let _ = fs::remove_dir_all(&stage);

    let mut result = std::collections::BTreeMap::new();
    let mut conflicts = Vec::new();
    let names: std::collections::BTreeSet<&String> = mine.keys().chain(theirs.keys()).collect();
    for name in names {
        let (m, t, b) = (mine.get(name), theirs.get(name), base.get(name));
        let merged_tombs;
        let pick = if m == t || t == b { m } else if m == b { t } else if name == tombstones::FILE {
            let text = |d: Option<&Vec<u8>>| d.map(|d| String::from_utf8_lossy(d).into_owned()).unwrap_or_default();
            let _ = b;
            merged_tombs = tombstones::merge_text(&text(m), &text(t)).into_bytes();
            Some(&merged_tombs)
        } else {
            match keep_mine.get(name.as_str()) {
                Some(true) => m,
                Some(false) => t,
                None => {
                    let text = |d: Option<&Vec<u8>>| d.map(|d| String::from_utf8_lossy(d).into_owned()).unwrap_or_default();
                    conflicts.push(SyncConflict { path: name.clone(), mine: text(m), theirs: text(t) });
                    continue;
                }
            }
        };
        if let Some(d) = pick { result.insert(name.clone(), d.clone()); }
    }
    if !conflicts.is_empty() { return Ok(SyncOutcome::Conflict { conflicts }); }

    let pushed = result.iter().any(|(k, v)| theirs.get(k) != Some(v));
    put_tree(folder_p, &result)?;
    let imported = sync_import(profile, paths, passphrase, folder.clone())?;
    // Пришло чужое: файл папки не совпал со своим или что-то влилось в локальные файлы (первая синхронизация).
    let pulled = !imported.is_empty() || result.iter().any(|(k, v)| mine.get(k) != Some(v));
    let _ = fs::remove_dir_all(&base_dir);
    put_tree(&base_dir, &result)?;
    Ok(if pulled || pushed || !imported.is_empty() { SyncOutcome::Synced { pulled, imported } } else { SyncOutcome::UpToDate })
}

#[cfg(test)]
mod git_error_tests {
    #[test]
    fn picks_meaningful_line() {
        let t = "Received disconnect from 1.2.3.4 port 22:2: Too many authentication failures\nDisconnected\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.";
        assert!(crate::ssh_errors::ssh_explain(super::git_error(t)).is_some());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(d: &Path) -> SyncPaths { SyncPaths { ssh: d.to_string_lossy().into(), support: d.to_string_lossy().into() } }
    const CONFIG: &str = "# relaya: group=work\nHost web\n    HostName 10.0.0.1\n\n# relaya: group=home\nHost nas\n    HostName 192.168.1.5\n\nHost github.com\n    User git\n";

    #[test]
    fn vault_roundtrip() {
        let blob = key_encrypt(b"PRIVATE".to_vec(), "pw".into(), MIN_ROUNDS);
        assert_eq!(key_decrypt(blob.clone(), "pw".into()).unwrap(), b"PRIVATE");
        assert_eq!(key_decrypt(blob.clone(), "nope".into()), Err(CoreError::Decrypt));
        // Итерации вне границ отвергаются сразу, без расчёта ключа.
        for rounds in [1u32, MIN_ROUNDS - 1, MAX_ROUNDS + 1, u32::MAX] {
            let mut bad = blob.clone();
            bad[21..25].copy_from_slice(&rounds.to_be_bytes());
            assert_eq!(key_decrypt(bad, "pw".into()), Err(CoreError::Decrypt));
        }
    }

    #[test]
    fn extract_merge() {
        let work = config_extract(CONFIG.into(), vec!["web".into()]);
        assert!(work.contains("Host web") && work.contains("# relaya: group=work") && !work.contains("nas"));
        let merged = config_merge("Host nas\n    HostName old\n\nHost web\n    HostName 1.1.1.1\n".into(), work);
        assert!(merged.contains("10.0.0.1") && !merged.contains("1.1.1.1") && merged.contains("HostName old"));
    }

    #[test]
    fn shared_blocks_split_on_export_and_import() {
        let shared = "# relaya: group=work\nHost a b\n    User x\n\nHost c\n    User y\n";
        assert_eq!(config_extract(shared.into(), vec!["a".into(), "c".into()]), "# relaya: group=work\nHost a\n    User x\n\nHost c\n    User y\n");
        assert_eq!(config_extract(shared.into(), vec!["a".into(), "b".into()]), "# relaya: group=work\nHost a b\n    User x\n");
        // Пришёл `Host a` — локальный `b` остаётся со своими настройками.
        assert_eq!(config_merge(shared.into(), "Host a\n    User new\n".into()),
                   "# relaya: group=work\nHost b\n    User x\n\nHost a\n    User new\n\nHost c\n    User y\n");
        // Пришёл общий `Host a b` — заменяет и общий, и отдельные локальные блоки, без дублей.
        assert_eq!(config_merge(shared.into(), "Host a b\n    User z\n".into()), "Host a b\n    User z\n\nHost c\n    User y\n");
        assert_eq!(config_merge("Host a\n    User 1\n\nHost m\n    User m\n\nHost b\n    User 2\n".into(), "Host a b\n    User z\n".into()),
                   "Host a b\n    User z\n\nHost m\n    User m\n");
    }

    #[test]
    fn scoped_export_import() {
        let (a, repo, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        fs::write(a.path().join("config"), CONFIG).unwrap();
        fs::write(a.path().join("tunnels.json"), r#"[{"autoStart":false,"hostAlias":"web","id":"T1","kind":"local","listenPort":1,"name":"w","targetHost":"x","targetPort":2},{"autoStart":false,"hostAlias":"nas","id":"T2","kind":"local","listenPort":3,"name":"n","targetHost":"y","targetPort":4}]"#).unwrap();
        let mut p = sync_new_profile("work".into());
        p.scope = SyncScope { all_hosts: false, groups: vec!["work".into()], hosts: vec![] };
        sync_export(p.clone(), paths(a.path()), None, repo.path().to_string_lossy().into()).unwrap();
        let exported = fs::read_to_string(repo.path().join("ssh/config")).unwrap();
        assert!(exported.contains("Host web") && !exported.contains("nas") && !exported.contains("github"));
        assert!(fs::read_to_string(repo.path().join("relaya/tunnels.json")).unwrap().contains("\"T1\"") );
        fs::write(b.path().join("config"), "Host mine\n    HostName m\n").unwrap();
        let ch = sync_import(p.clone(), paths(b.path()), None, repo.path().to_string_lossy().into()).unwrap();
        assert!(ch.contains(&SyncItem::SshConfig) && ch.contains(&SyncItem::Tunnels));
        let merged = fs::read_to_string(b.path().join("config")).unwrap();
        assert!(merged.contains("Host mine") && merged.contains("Host web") && b.path().join("config.bak").exists());
        assert!(sync_import(p, paths(b.path()), None, repo.path().to_string_lossy().into()).unwrap().is_empty());
    }

    #[test]
    fn git_two_machines_conflict() {
        let bare = tempfile::tempdir().unwrap();
        assert!(std::process::Command::new("git").args(["init", "-q", "--bare", "-b", "main"]).arg(bare.path()).status().unwrap().success());
        let (la, lb, ra, rb) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (ra, rb) = (ra.path().join("repo").to_string_lossy().to_string(), rb.path().join("repo").to_string_lossy().to_string());
        let remote = bare.path().to_string_lossy().to_string();
        let p = sync_new_profile("all".into());
        fs::write(la.path().join("config"), "Host a\n    HostName 1\n").unwrap();
        assert_eq!(git_sync(ra.clone(), remote.clone(), "A".into(), p.clone(), paths(la.path()), None).unwrap(),
                   SyncOutcome::Synced { pulled: false, imported: vec![] });
        // Вторая машина: подтягивает с сервера (setUp сбрасывает на origin) и разносит.
        let out = git_sync(rb.clone(), remote.clone(), "B".into(), p.clone(), paths(lb.path()), None).unwrap();
        assert!(matches!(&out, SyncOutcome::Synced { imported, .. } if imported.contains(&SyncItem::SshConfig)), "{out:?}");
        assert!(fs::read_to_string(Path::new(&rb).join("ssh/config")).unwrap().contains("Host a"), "пустой Mac не должен обнулять общий файл");
        // Первое подключение разносит пришедшее само, без ручного sync_import.
        assert!(fs::read_to_string(lb.path().join("config")).unwrap().contains("Host a"));

        fs::write(la.path().join("config"), "Host a\n    HostName from-A\n").unwrap();
        git_sync(ra, remote.clone(), "A".into(), p.clone(), paths(la.path()), None).unwrap();
        fs::write(lb.path().join("config"), "Host a\n    HostName from-B\n").unwrap();
        let SyncOutcome::Conflict { conflicts } = git_sync(rb.clone(), remote.clone(), "B".into(), p.clone(), paths(lb.path()), None).unwrap()
            else { panic!("expected conflict") };
        assert_eq!(conflicts[0].path, "ssh/config");
        assert!(conflicts[0].mine.contains("from-B") && conflicts[0].theirs.contains("from-A"));
        git_resolve(rb.clone(), [("ssh/config".to_string(), false)].into(), p.clone(), paths(lb.path()), None).unwrap();
        assert!(fs::read_to_string(lb.path().join("config")).unwrap().contains("from-A"));
        assert_eq!(git_sync(rb, remote, "B".into(), p, paths(lb.path()), None).unwrap(), SyncOutcome::UpToDate);
    }

    #[test]
    fn folder_merges_three_way_and_reports_conflicts() {
        let (folder, a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let f = folder.path().to_string_lossy().to_string();
        let p = sync_new_profile("all".into());
        let none = std::collections::HashMap::new();
        fs::write(a.path().join("config"), "Host web\n    HostName 1.1.1.1\n").unwrap();
        assert!(matches!(folder_sync_merge(p.clone(), paths(a.path()), None, f.clone(), none.clone()).unwrap(), SyncOutcome::Synced { .. }));
        // Вторая машина получает чужое и добавляет своё.
        fs::write(b.path().join("config"), "Host nas\n    HostName 2.2.2.2\n").unwrap();
        let out = folder_sync_merge(p.clone(), paths(b.path()), None, f.clone(), none.clone()).unwrap();
        assert!(matches!(out, SyncOutcome::Synced { pulled: true, .. }), "{out:?}");
        let cfg_b = fs::read_to_string(b.path().join("config")).unwrap();
        assert!(cfg_b.contains("1.1.1.1") && cfg_b.contains("2.2.2.2"), "{cfg_b}");
        // Без изменений — UpToDate.
        assert_eq!(folder_sync_merge(p.clone(), paths(b.path()), None, f.clone(), none.clone()).unwrap(), SyncOutcome::UpToDate);
        // Обе машины поменяли web по-разному — конфликт, папка не тронута.
        let _ = folder_sync_merge(p.clone(), paths(a.path()), None, f.clone(), none.clone()).unwrap();
        fs::write(a.path().join("config"), "Host web\n    HostName 9.9.9.9\n\nHost nas\n    HostName 2.2.2.2\n").unwrap();
        assert!(matches!(folder_sync_merge(p.clone(), paths(a.path()), None, f.clone(), none.clone()).unwrap(), SyncOutcome::Synced { .. }));
        fs::write(b.path().join("config"), cfg_b.replace("1.1.1.1", "5.5.5.5")).unwrap();
        let before = fs::read(folder.path().join("ssh/config")).unwrap();
        let SyncOutcome::Conflict { conflicts } = folder_sync_merge(p.clone(), paths(b.path()), None, f.clone(), none.clone()).unwrap()
            else { panic!("ожидался конфликт") };
        assert_eq!(conflicts.len(), 1);
        assert_eq!(conflicts[0].path, "ssh/config");
        assert!(conflicts[0].mine.contains("5.5.5.5") && conflicts[0].theirs.contains("9.9.9.9"));
        assert_eq!(fs::read(folder.path().join("ssh/config")).unwrap(), before);
        // Разрешение «из папки»: на b приходит 9.9.9.9.
        let keep: std::collections::HashMap<String, bool> = [("ssh/config".to_string(), false)].into();
        assert!(matches!(folder_sync_merge(p.clone(), paths(b.path()), None, f.clone(), keep).unwrap(), SyncOutcome::Synced { .. }));
        assert!(fs::read_to_string(b.path().join("config")).unwrap().contains("9.9.9.9"));
    }

    #[test]
    fn broken_json_stops_sync_without_overwriting() {
        let (a, dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        fs::create_dir_all(dir.path().join("relaya")).unwrap();
        fs::write(dir.path().join("relaya/tunnels.json"), "[]").unwrap();
        fs::write(a.path().join("tunnels.json"), "[{broken").unwrap();
        let p = sync_new_profile("all".into());
        let d = dir.path().to_string_lossy().to_string();
        assert!(matches!(sync_import(p.clone(), paths(a.path()), None, d.clone()), Err(CoreError::Json(_))));
        assert_eq!(fs::read_to_string(a.path().join("tunnels.json")).unwrap(), "[{broken");
        assert!(a.path().join("tunnels.json.bak").exists());
        assert!(matches!(sync_export(p, paths(a.path()), None, d), Err(CoreError::Json(_))));
        assert_eq!(fs::read_to_string(dir.path().join("relaya/tunnels.json")).unwrap(), "[]");
    }

    #[test]
    fn imported_mac_config_is_readable_by_local_ssh() {
        let (a, dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        fs::create_dir_all(dir.path().join("ssh")).unwrap();
        fs::write(dir.path().join("ssh/config"), "Host m\n    IdentityFile ~/.ssh/k\n    UseKeychain yes\n").unwrap();
        sync_import(sync_new_profile("all".into()), paths(a.path()), None, dir.path().to_string_lossy().into()).unwrap();
        let cfg = fs::read_to_string(a.path().join("config")).unwrap();
        assert_eq!(cfg.starts_with("IgnoreUnknown UseKeychain\n"), !cfg!(target_os = "macos"), "{cfg}");
    }

    #[test]
    fn deletions_travel_via_tombstones() {
        let bare = tempfile::tempdir().unwrap();
        assert!(std::process::Command::new("git").args(["init", "-q", "--bare", "-b", "main"]).arg(bare.path()).status().unwrap().success());
        let (la, lb, ra, rb) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (ra, rb) = (ra.path().join("repo").to_string_lossy().to_string(), rb.path().join("repo").to_string_lossy().to_string());
        let remote = bare.path().to_string_lossy().to_string();
        let p = sync_new_profile("all".into());
        fs::write(la.path().join("config"), "Host keep\n    HostName 1\n\nHost openwrt\n    HostName 192.168.1.1\n").unwrap();
        fs::write(la.path().join("snippets.json"), r#"[{"command":"ls","id":"S1","name":"a"},{"command":"df","id":"S2","name":"b"}]"#).unwrap();
        git_sync(ra.clone(), remote.clone(), "A".into(), p.clone(), paths(la.path()), None).unwrap();
        git_sync(rb.clone(), remote.clone(), "B".into(), p.clone(), paths(lb.path()), None).unwrap();
        assert!(fs::read_to_string(lb.path().join("config")).unwrap().contains("openwrt"));

        // B удаляет openwrt и сниппет S2 — после синхронизации их нет ни в общем, ни на A.
        fs::write(lb.path().join("config"), "Host keep\n    HostName 1\n").unwrap();
        fs::write(lb.path().join("snippets.json"), r#"[{"command":"ls","id":"S1","name":"a"}]"#).unwrap();
        git_sync(rb.clone(), remote.clone(), "B".into(), p.clone(), paths(lb.path()), None).unwrap();
        assert!(!fs::read_to_string(Path::new(&rb).join("ssh/config")).unwrap().contains("openwrt"));
        assert!(fs::read_to_string(Path::new(&rb).join(tombstones::FILE)).unwrap().contains("openwrt"));
        git_sync(ra.clone(), remote.clone(), "A".into(), p.clone(), paths(la.path()), None).unwrap();
        let cfg_a = fs::read_to_string(la.path().join("config")).unwrap();
        assert!(!cfg_a.contains("openwrt") && cfg_a.contains("Host keep"), "{cfg_a}");
        assert!(!fs::read_to_string(la.path().join("snippets.json")).unwrap().contains("S2"));
        // Повторная синхронизация ничего не возвращает.
        git_sync(rb.clone(), remote.clone(), "B".into(), p.clone(), paths(lb.path()), None).unwrap();
        git_sync(ra.clone(), remote.clone(), "A".into(), p.clone(), paths(la.path()), None).unwrap();
        assert!(!fs::read_to_string(la.path().join("config")).unwrap().contains("openwrt"));
        assert!(!fs::read_to_string(lb.path().join("config")).unwrap().contains("openwrt"));

        // Пустая машина ничего не стирает.
        let (lc, rc) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let rc = rc.path().join("repo").to_string_lossy().to_string();
        git_sync(rc.clone(), remote.clone(), "C".into(), p.clone(), paths(lc.path()), None).unwrap();
        fs::write(lc.path().join("config"), "").unwrap();
        git_sync(rc, remote.clone(), "C".into(), p.clone(), paths(lc.path()), None).unwrap();
        git_sync(ra.clone(), remote.clone(), "A".into(), p.clone(), paths(la.path()), None).unwrap();
        assert!(fs::read_to_string(la.path().join("config")).unwrap().contains("Host keep"));
    }

    #[test]
    fn edit_after_delete_wins_and_tombstones_merge() {
        let (folder, a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let f = folder.path().to_string_lossy().to_string();
        let p = sync_new_profile("all".into());
        let none = std::collections::HashMap::new();
        fs::write(a.path().join("config"), "Host x\n    HostName 1\n\nHost y\n    HostName 2\n").unwrap();
        folder_sync_merge(p.clone(), paths(a.path()), None, f.clone(), none.clone()).unwrap();
        folder_sync_merge(p.clone(), paths(b.path()), None, f.clone(), none.clone()).unwrap();
        // A удаляет x, B тем временем правит x: на общем файле конфликт; «оставить своё» — правка побеждает и
        // возвращается на A, надгробие воскрешено.
        fs::write(a.path().join("config"), "Host y\n    HostName 2\n").unwrap();
        folder_sync_merge(p.clone(), paths(a.path()), None, f.clone(), none.clone()).unwrap();
        fs::write(b.path().join("config"), "Host x\n    HostName 9\n\nHost y\n    HostName 2\n").unwrap();
        let SyncOutcome::Conflict { conflicts } = folder_sync_merge(p.clone(), paths(b.path()), None, f.clone(), none.clone()).unwrap()
            else { panic!("ожидался конфликт") };
        assert_eq!(conflicts.iter().map(|c| c.path.as_str()).collect::<Vec<_>>(), ["ssh/config"], "deleted.json сливается сам");
        let keep: std::collections::HashMap<String, bool> = [("ssh/config".to_string(), true)].into();
        folder_sync_merge(p.clone(), paths(b.path()), None, f.clone(), keep).unwrap();
        assert!(fs::read_to_string(b.path().join("config")).unwrap().contains("HostName 9"));
        folder_sync_merge(p.clone(), paths(a.path()), None, f.clone(), none.clone()).unwrap();
        assert!(fs::read_to_string(a.path().join("config")).unwrap().contains("HostName 9"));
        folder_sync_merge(p.clone(), paths(b.path()), None, f.clone(), none.clone()).unwrap();
        assert!(fs::read_to_string(b.path().join("config")).unwrap().contains("HostName 9"), "воскрешённое не удаляется снова");

        let t = |k: &str, at: &str, rev: Option<&str>| Tombstone { kind: "host".into(), key: k.into(), deleted_at: at.into(),
                                                                  machine: "m".into(), revived_at: rev.map(Into::into) };
        let enc = |v: Vec<Tombstone>| encode_sorted(&v);
        let merged = tombstones::merge_text(&enc(vec![t("a", "2026-01-01T00:00:00Z", None)]), &enc(vec![t("b", "2026-01-02T00:00:00Z", None)]));
        assert!(merged.contains("\"a\"") && merged.contains("\"b\""));
        // Позднее событие побеждает: воскрешение после удаления сохраняется при слиянии.
        let m = tombstones::merge_text(&enc(vec![t("a", "2026-01-01T00:00:00Z", Some("2026-01-03T00:00:00Z"))]),
                                       &enc(vec![t("a", "2026-01-01T00:00:00Z", None)]));
        assert!(m.contains("revivedAt"));
    }
}

// MARK: - Удаления (надгробия)

/// Что лежит локально для профиля: (вид, ключ) → хеш содержимого. Хосты — по алиасу, остальное — по id.
type Items = std::collections::BTreeMap<(String, String), String>;

fn digest(s: &str) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(s.as_bytes()).iter().take(8).map(|b| format!("{b:02x}")).collect()
}

fn local_items(profile: &SyncProfile, paths: &SyncPaths) -> Result<Items, CoreError> {
    let items = profile.effective_items();
    let mut out = Items::new();
    let text = fs::read_to_string(paths.config()).unwrap_or_default();
    let hosts: Vec<_> = parse_config(text.clone()).into_iter().filter(|h| profile.contains(h) && !h.is_git_service()).collect();
    let aliases_set: HashSet<String> = hosts.iter().map(|h| h.alias.clone()).collect();
    if items.contains(&SyncItem::SshConfig) {
        let doc = Document::new(&text);
        for h in &hosts { out.insert(("host".into(), h.alias.clone()), digest(&doc.current_lines(&h.alias).join("\n"))); }
    }
    let read_list = |name: &str| -> Result<Vec<serde_json::Value>, CoreError> {
        match fs::read_to_string(paths.support(name)) { Ok(j) => try_decode_list(&j).map_err(|e| broken(name, e)), Err(_) => Ok(vec![]) }
    };
    let id = |v: &serde_json::Value| v.get("id").and_then(|x| x.as_str()).unwrap_or("").to_string();
    if items.contains(&SyncItem::Snippets) {
        for v in read_list("snippets.json")? { out.insert(("snippet".into(), id(&v)), digest(&encode_sorted(&v))); }
    }
    if items.contains(&SyncItem::Tunnels) {
        for v in read_list("tunnels.json")? {
            if v.get("hostAlias").and_then(|x| x.as_str()).map(|a| aliases_set.contains(a)).unwrap_or(false) {
                out.insert(("tunnel".into(), id(&v)), digest(&encode_sorted(&v)));
            }
        }
    }
    if items.contains(&SyncItem::Desktops) {
        for v in read_list("desktops.json")? {
            let ok = profile.scope.all_hosts
                || v.get("group").and_then(|x| x.as_str()).map(|g| profile.scope.groups.iter().any(|x| x == g)).unwrap_or(false)
                || v.get("viaSSHHost").and_then(|x| x.as_str()).map(|a| aliases_set.contains(a)).unwrap_or(false);
            if ok { out.insert(("desktop".into(), id(&v)), digest(&encode_sorted(&v))); }
        }
    }
    Ok(out)
}

/// Запись в `relaya/deleted.json`: когда элемент удалили и, если правили потом, когда «воскресили».
/// Действует более позднее из двух событий, поэтому записи двух машин сливаются без конфликтов.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Tombstone {
    pub kind: String,
    pub key: String,
    pub deleted_at: String,
    pub machine: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub revived_at: Option<String>,
}

impl Tombstone {
    fn dead(&self) -> bool { self.revived_at.as_deref().map(|r| r < self.deleted_at.as_str()).unwrap_or(true) }
    /// Последнее событие записи: удаление или воскрешение.
    fn last(&self) -> &str { self.revived_at.as_deref().filter(|r| *r > self.deleted_at.as_str()).unwrap_or(&self.deleted_at) }
}

pub(crate) mod tombstones {
    use super::*;

    pub(crate) const FILE: &str = "relaya/deleted.json";
    /// Записи старше этого срока уже разошлись по машинам и удаляются.
    const KEEP_DAYS: i64 = 90;

    /// Снимок после прошлой синхронизации: (вид, ключ) → (хеш, когда хеш последний раз менялся).
    type Snapshot = std::collections::BTreeMap<(String, String), (String, String)>;

    /// ISO 8601 в UTC с миллисекундами: строки сравниваются по времени.
    fn now() -> String { chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string() }

    fn machine() -> String {
        std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_else(|_| "unknown".into())
    }

    fn snapshot_file(profile: &SyncProfile, paths: &SyncPaths) -> PathBuf {
        Path::new(&paths.support).join("sync").join(&profile.id).join("known.json")
    }

    fn load_snapshot(profile: &SyncProfile, paths: &SyncPaths) -> Snapshot {
        let list: Vec<(String, String, String, String)> = fs::read_to_string(snapshot_file(profile, paths)).ok()
            .and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        list.into_iter().map(|(k, key, h, at)| ((k, key), (h, at))).collect()
    }

    /// Запомнить локальное состояние; `keep` — ключи, которые остаются в снимке до импорта (свежие удаления).
    pub(crate) fn save_snapshot(profile: &SyncProfile, paths: &SyncPaths, local: &Items, keep: &[Tombstone]) -> Result<(), CoreError> {
        let old = load_snapshot(profile, paths);
        let t = now();
        let mut snap: Snapshot = local.iter().map(|(k, h)| {
            let at = old.get(k).filter(|(oh, _)| oh == h).map(|(_, at)| at.clone()).unwrap_or_else(|| t.clone());
            (k.clone(), (h.clone(), at))
        }).collect();
        for (k, v) in old { if !snap.contains_key(&k) && keep.iter().any(|x| x.dead() && x.kind == k.0 && x.key == k.1) { snap.insert(k, v); } }
        let f = snapshot_file(profile, paths);
        if let Some(d) = f.parent() { fs::create_dir_all(d)?; }
        let list: Vec<(&String, &String, &String, &String)> = snap.iter().map(|((k, key), (h, at))| (k, key, h, at)).collect();
        fs::write(f, serde_json::to_string(&list)?)?;
        Ok(())
    }

    pub(crate) fn load(dir: &Path) -> Result<Vec<Tombstone>, CoreError> {
        match fs::read_to_string(dir.join(FILE)) { Ok(s) => try_decode_list(&s).map_err(|e| broken(FILE, e)), Err(_) => Ok(vec![]) }
    }

    /// Слить записи: по каждому ключу — с самым поздним событием.
    pub(crate) fn union(a: Vec<Tombstone>, b: Vec<Tombstone>) -> Vec<Tombstone> {
        let mut m: std::collections::BTreeMap<(String, String), Tombstone> = Default::default();
        for t in a.into_iter().chain(b) {
            let k = (t.kind.clone(), t.key.clone());
            match m.get(&k) { Some(o) if o.last() >= t.last() => {}, _ => { m.insert(k, t); } }
        }
        m.into_values().collect()
    }

    /// Слияние текстов `deleted.json` (git-конфликт, папка): union, база не нужна.
    pub(crate) fn merge_text(mine: &str, theirs: &str) -> String {
        let p = |s: &str| serde_json::from_str::<Vec<Tombstone>>(s).unwrap_or_default();
        encode_sorted(&union(p(mine), p(theirs)))
    }

    /// Записи для выгрузки: новые удаления (было в снимке, исчезло локально) и воскрешения (элемент здесь правили
    /// после удаления на другой машине — правка побеждает). Пустая машина ничего не хоронит.
    pub(crate) fn prepare(profile: &SyncProfile, paths: &SyncPaths, dir: &Path, local: &Items) -> Result<Vec<Tombstone>, CoreError> {
        let known = load_snapshot(profile, paths);
        let mut tombs = load(dir)?;
        let t = now();
        for ((kind, key), _) in known.iter().filter(|(k, _)| !local.contains_key(*k)) {
            // Пропали разом все элементы вида — скорее пустой или сломанный файл, чем удаление.
            if !local.keys().any(|(k, _)| k == kind) { continue; }
            match tombs.iter_mut().find(|x| &x.kind == kind && &x.key == key) {
                Some(x) if x.dead() => {}
                Some(x) => { x.deleted_at = t.clone(); x.revived_at = None; x.machine = machine(); }
                None => tombs.push(Tombstone { kind: kind.clone(), key: key.clone(), deleted_at: t.clone(), machine: machine(), revived_at: None }),
            }
        }
        for x in tombs.iter_mut().filter(|x| x.dead()) {
            let k = (x.kind.clone(), x.key.clone());
            let Some(h) = local.get(&k) else { continue };
            // Изменилось после удаления (или пришло позже) — воскрешаем.
            let changed_at = match known.get(&k) { Some((kh, at)) if kh == h => at.clone(), _ => t.clone() };
            // Правка в ту же миллисекунду, что и удаление, считается более поздней: правка побеждает.
            if changed_at >= x.deleted_at { x.revived_at = Some(t.clone()); }
        }
        let cutoff = (chrono::Utc::now() - chrono::Duration::days(KEEP_DAYS)).format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string();
        tombs.retain(|x| x.last() >= cutoff.as_str());
        Ok(tombs)
    }

    /// Убрать похороненное из общих файлов и записать `deleted.json`.
    pub(crate) fn strip_shared(dir: &Path, tombs: &mut Vec<Tombstone>, changed: &mut Vec<String>) -> Result<(), CoreError> {
        if tombs.is_empty() && !dir.join(FILE).exists() { return Ok(()); }
        let gone = |kind: &str, key: &str| tombs.iter().any(|t| t.dead() && t.kind == kind && t.key == key);
        if let Ok(text) = fs::read_to_string(dir.join("ssh/config")) {
            let mut doc = Document::new(&text);
            let mut cut = false;
            for a in parse_config(text.clone()).into_iter().map(|h| h.alias).filter(|a| gone("host", a)) {
                while take_alias(&mut doc, &a).is_some() { cut = true; }
            }
            if cut {
                while doc.lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) { doc.lines.pop(); }
                write_if_changed(dir, "ssh/config", doc.text().as_bytes(), changed)?;
            }
        }
        for (kind, rel) in [("snippet", "relaya/snippets.json"), ("tunnel", "relaya/tunnels.json"), ("desktop", "relaya/desktops.json")] {
            let Ok(j) = fs::read_to_string(dir.join(rel)) else { continue };
            let list: Vec<serde_json::Value> = try_decode_list(&j).map_err(|e| broken(rel, e))?;
            let kept: Vec<serde_json::Value> = list.iter().filter(|v| !gone(kind, v.get("id").and_then(|x| x.as_str()).unwrap_or(""))).cloned().collect();
            if kept.len() != list.len() { write_if_changed(dir, rel, encode_sorted(&kept).as_bytes(), changed)?; }
        }
        tombs.sort_by(|a, b| (&a.kind, &a.key).cmp(&(&b.kind, &b.key)));
        write_if_changed(dir, FILE, encode_sorted(&tombs).as_bytes(), changed)?;
        Ok(())
    }

    /// Удалить локально то, что похоронено и не менялось здесь после удаления.
    pub(crate) fn apply_locally(profile: &SyncProfile, paths: &SyncPaths, dir: &Path) -> Result<Vec<SyncItem>, CoreError> {
        let tombs = load(dir)?;
        if !tombs.iter().any(|t| t.dead()) { return Ok(vec![]); }
        let known = load_snapshot(profile, paths);
        let local = local_items(profile, paths)?;
        let doomed = |kind: &str, key: &str| {
            let k = (kind.to_string(), key.to_string());
            let Some(t) = tombs.iter().find(|t| t.dead() && t.kind == kind && t.key == key) else { return false };
            match (local.get(&k), known.get(&k)) {
                (Some(h), Some((kh, at))) => h == kh && at.as_str() < t.deleted_at.as_str(),
                _ => false,
            }
        };
        let mut changed = Vec::new();
        if let Ok(text) = fs::read_to_string(paths.config()) {
            let mut doc = Document::new(&text);
            let mut cut = false;
            for h in parse_config(text.clone()) {
                if doomed("host", &h.alias) { while take_alias(&mut doc, &h.alias).is_some() { cut = true; } }
            }
            if cut {
                while doc.lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) { doc.lines.pop(); }
                let bak = Path::new(&paths.ssh).join("config.bak");
                fs::copy(paths.config(), &bak).map_err(|e| CoreError::Io(format!("config.bak: {e}")))?;
                set_private(&bak);
                write_private_atomic(&paths.config(), doc.text().as_bytes())?;
                changed.push(SyncItem::SshConfig);
            }
        }
        for (kind, name, item) in [("snippet", "snippets.json", SyncItem::Snippets), ("tunnel", "tunnels.json", SyncItem::Tunnels),
                                   ("desktop", "desktops.json", SyncItem::Desktops)] {
            let Ok(j) = fs::read_to_string(paths.support(name)) else { continue };
            let list: Vec<serde_json::Value> = try_decode_list(&j).map_err(|e| broken(name, e))?;
            let kept: Vec<serde_json::Value> = list.iter().filter(|v| !doomed(kind, v.get("id").and_then(|x| x.as_str()).unwrap_or(""))).cloned().collect();
            if kept.len() != list.len() {
                write_atomic(&paths.support(name), encode_sorted(&kept).as_bytes())?;
                changed.push(item);
            }
        }
        Ok(changed)
    }
}
