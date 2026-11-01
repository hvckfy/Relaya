//! Правила моста WebDAV без сети: какой путь на сервере можно трогать, что сделать по запросу и каким кодом
//! ответить. Клиенты (Mac, Windows, Linux) только выполняют решение через sftp/ssh — сами пути не проверяют.

use crate::error::CoreError;
use crate::shell_quote;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// Логин Basic-аутентификации моста; пароль — случайный на каждое подключение диска.
pub const DAV_USER: &str = "relaya";

/// Секреты одного подключения диска: путь `/<uuid>/<имя диска>` и Basic-пароль. Оба случайные, чтобы
/// другой локальный процесс, узнавший порт, не добрался до файлов хоста.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DavSecrets {
    pub user: String,
    pub password: String,
    pub prefix: String,
}

/// Новые секреты для диска `volume_name` (имя из `dav_volume_name`, без `/`).
#[uniffi::export]
pub fn dav_new_secrets(volume_name: String) -> DavSecrets {
    let password = format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple());
    DavSecrets {
        user: DAV_USER.into(),
        password,
        prefix: format!("/{}/{}", uuid::Uuid::new_v4().simple(), volume_name),
    }
}

/// Совпадает ли заголовок `Authorization` с Basic `relaya:<password>`. Нет заголовка, другая схема или другой
/// пароль — false. Сравнение за постоянное время, чтобы по задержке нельзя было подбирать пароль.
#[uniffi::export]
pub fn dav_authorized(authorization: Option<String>, password: String) -> bool {
    let expected = format!("Basic {}", base64(format!("{DAV_USER}:{password}")));
    let Some(got) = authorization else { return false };
    let (a, b) = (got.trim().as_bytes(), expected.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Имя диска: хост, для вложенной папки — «хост · папка», для домашней — «хост · ~». `/` заменяется на `-`,
/// чтобы имя оставалось одним компонентом пути.
#[uniffi::export]
pub fn dav_volume_name(alias: String, path: String) -> String {
    let last = path.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let name = if path.is_empty() || path == "/" || last.is_empty() {
        alias
    } else if path == "~" {
        format!("{alias} · ~")
    } else {
        format!("{alias} · {last}")
    };
    name.replace('/', "-")
}

/// Нужна ли домашняя папка, чтобы разрешить корень диска: пустое, `~` и `~/…`.
#[uniffi::export]
pub fn dav_root_needs_home(requested: String) -> bool {
    let r = requested.trim();
    r.is_empty() || r == "~" || r.starts_with("~/")
}

/// Корень диска на сервере: пустое и `~` — `home`, `~/x` — внутри `home`, иначе абсолютный путь (без `/` в
/// начале — добавляется). `.` и `..` в компонентах — ошибка: корень не должен уходить выше, чем назван.
/// Существование папки проверяет клиент (листинг).
#[uniffi::export]
pub fn dav_resolve_root(requested: String, home: String) -> Result<String, CoreError> {
    let r = requested.trim();
    let raw = if r.is_empty() || r == "~" {
        home.clone()
    } else if let Some(rest) = r.strip_prefix("~/") {
        join(&home, rest)
    } else {
        r.to_string()
    };
    normalize(&raw).ok_or(CoreError::InvalidValue(requested))
}

/// Путь запроса → путь на сервере. Только внутри `prefix` (с границей `/`), без `.`/`..` и NUL в компонентах —
/// ни запрос, ни Destination у MOVE/COPY не выходят за корень диска. Пустые компоненты (`//`) схлопываются.
#[uniffi::export]
pub fn dav_remote_path(prefix: String, root: String, path: String) -> Option<String> {
    let rest = path.strip_prefix(prefix.as_str())?;
    if !rest.is_empty() && !rest.starts_with('/') {
        return None;
    }
    let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
    if parts.iter().any(|p| *p == "." || *p == ".." || p.contains('\0')) {
        return None;
    }
    Some(if parts.is_empty() { root } else { join(&root, &parts.join("/")) })
}

/// Что сделать по запросу. Пути — уже на сервере и внутри корня; `junk` — служебный файл Finder, который живёт
/// только в памяти моста и на сервер не попадает.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DavAction {
    /// Ответить кодом без обращения к серверу (401 здесь не бывает — его решает `dav_authorized`).
    Reply {
        status: u16,
        reason: String,
    },
    Options,
    Propfind {
        remote: String,
        junk: bool,
    },
    Proppatch,
    Lock,
    Unlock,
    Get {
        remote: String,
        junk: bool,
    },
    Head {
        remote: String,
        junk: bool,
    },
    Put {
        remote: String,
        junk: bool,
    },
    Mkcol {
        remote: String,
    },
    Delete {
        remote: String,
        junk: bool,
    },
    /// MOVE/COPY. Для обычных файлов клиент проверяет, есть ли `destination`, и зовёт `dav_transfer_plan`.
    Transfer {
        source: String,
        destination: String,
        is_move: bool,
        overwrite: bool,
        junk: bool,
    },
}

/// Решение по запросу (после проверки пароля). Вне корня — 404; DELETE/MOVE самого корня — 403; MOVE/COPY без
/// Destination или с Destination вне корня — 400; Destination == источник — 403 (RFC 4918 9.8.5);
/// неизвестный метод — 405. OPTIONS — на любой путь, даже вне префикса. `Overwrite` по умолчанию T; F — только явное `F`.
#[uniffi::export]
pub fn dav_decide(
    method: String,
    path: String,
    destination: Option<String>,
    overwrite: Option<String>,
    prefix: String,
    root: String,
) -> DavAction {
    let reply = |status: u16, reason: &str| DavAction::Reply { status, reason: reason.into() };
    // OPTIONS не раскрывает файлов: WebClient (Windows) спрашивает его у корня сервера, вне секретного пути.
    if method == "OPTIONS" {
        return DavAction::Options;
    }
    let Some(remote) = dav_remote_path(prefix.clone(), root.clone(), path) else { return reply(404, "Not Found") };
    let is_root = remote == root;
    if is_root && (method == "DELETE" || method == "MOVE") {
        return reply(403, "Forbidden");
    }
    let junk = !is_root && crate::webdav::dav_is_finder_junk(base_name(&remote).into());
    match method.as_str() {
        "OPTIONS" => DavAction::Options,
        "PROPFIND" => DavAction::Propfind { remote, junk },
        "PROPPATCH" => DavAction::Proppatch,
        "LOCK" => DavAction::Lock,
        "UNLOCK" => DavAction::Unlock,
        "GET" => DavAction::Get { remote, junk },
        "HEAD" => DavAction::Head { remote, junk },
        "PUT" if is_root => reply(405, "Method Not Allowed"),
        "PUT" => DavAction::Put { remote, junk },
        "MKCOL" if is_root => reply(405, "Method Not Allowed"),
        "MKCOL" => DavAction::Mkcol { remote },
        "DELETE" => DavAction::Delete { remote, junk },
        "MOVE" | "COPY" => {
            let dest =
                crate::webdav::dav_destination_path(destination).and_then(|d| dav_remote_path(prefix, root.clone(), d));
            let Some(dest) = dest else { return reply(400, "Bad Request") };
            if dest == remote || dest == root {
                return reply(403, "Forbidden");
            }
            // Папку нельзя положить внутрь неё самой: mv/cp ушли бы в рекурсию или ошибку после частичной работы.
            if dest.starts_with(&format!("{}/", remote.trim_end_matches('/'))) {
                return reply(403, "Forbidden");
            }
            let overwrite = !overwrite.is_some_and(|o| o.trim().eq_ignore_ascii_case("F"));
            DavAction::Transfer { source: remote, destination: dest, is_move: method == "MOVE", overwrite, junk }
        }
        _ => reply(405, "Method Not Allowed"),
    }
}

/// MOVE/COPY обычного файла, когда клиент узнал, есть ли цель.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DavTransferPlan {
    /// Overwrite: F, цель есть — 412 (RFC 4918 9.9.3); `mv -n` молча ничего не сделал бы и клиент получил бы 201.
    Reply { status: u16, reason: String },
    /// Выполнить `command` на хосте (ssh) и при успехе ответить `status`: 204 — цель заменена, 201 — создана
    /// (RFC 4918 9.9.4). Замена сначала удаляет папку-цель: иначе mv/cp положили бы источник внутрь неё.
    Run { command: String, status: u16, reason: String },
}

#[uniffi::export]
pub fn dav_transfer_plan(
    source: String,
    destination: String,
    is_move: bool,
    overwrite: bool,
    destination_exists: bool,
) -> DavTransferPlan {
    if destination_exists && !overwrite {
        return DavTransferPlan::Reply { status: 412, reason: "Precondition Failed".into() };
    }
    let (s, d) = (shell_quote(&source), shell_quote(&destination));
    let tool = if is_move { "mv" } else { "cp -a" };
    let clear = if destination_exists { format!("{{ ! test -d {d} || rm -rf -- {d}; }} && ") } else { String::new() };
    let (status, reason) = if destination_exists { (204, "No Content") } else { (201, "Created") };
    DavTransferPlan::Run { command: format!("{clear}{tool} -- {s} {d}"), status, reason: reason.into() }
}

/// Команда удаления на хосте: папки — целиком (файловый менеджер сам спрашивает подтверждение).
#[uniffi::export]
pub fn dav_delete_command(remote: String) -> String {
    format!("rm -rf -- {}", shell_quote(&remote))
}

/// Команда «есть ли путь» (файл, папка или висячая ссылка): код 0 — есть, 1 — нет, иное — ошибка ssh.
#[uniffi::export]
pub fn dav_exists_command(remote: String) -> String {
    let q = shell_quote(&remote);
    format!("test -e {q} || test -L {q}")
}

/// Новый путь временного файла для GET/PUT: в каталоге процесса `relaya-dav-<pid>` с правами 0700 (на Linux — в
/// XDG_RUNTIME_DIR, иначе temp_dir). Содержимое чужих файлов не ложится в общий /tmp по umask. Сам файл не
/// создаётся; удаляет его клиент после запроса, каталог — `dav_temp_cleanup` при выходе.
#[uniffi::export]
pub fn dav_temp_file() -> Result<String, CoreError> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = temp_dir();
    create_private_dir(&dir)?;
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    Ok(dir.join(format!("{n}-{}", uuid::Uuid::new_v4().simple())).to_string_lossy().into_owned())
}

/// Удалить каталог временных файлов процесса (выход из приложения). Нет каталога — не ошибка.
#[uniffi::export]
pub fn dav_temp_cleanup() -> Result<(), CoreError> {
    match std::fs::remove_dir_all(temp_dir()) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
        _ => Ok(()),
    }
}

fn temp_dir() -> PathBuf {
    crate::openh264::copies_root().join(format!("relaya-dav-{}", std::process::id()))
}

/// Создать каталог 0700 или принять уже свой: чужой (не каталог, ссылка, другие права) — ошибка, а не запись в него.
fn create_private_dir(dir: &std::path::Path) -> Result<(), CoreError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
        match std::fs::DirBuilder::new().mode(0o700).create(dir) {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() != std::io::ErrorKind::AlreadyExists => return Err(e.into()),
            Err(_) => {}
        }
        let meta = std::fs::symlink_metadata(dir)?;
        let own = meta.uid() == unsafe_getuid();
        if !meta.is_dir() || !own || meta.permissions().mode() & 0o077 != 0 {
            return Err(CoreError::Io(format!("{}: unsafe directory", dir.display())));
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        // Windows: %TEMP% и так в профиле пользователя.
        std::fs::create_dir_all(dir)?;
        Ok(())
    }
}

#[cfg(unix)]
fn unsafe_getuid() -> u32 {
    extern "C" {
        fn getuid() -> u32;
    }
    // SAFETY: getuid не принимает аргументов и не может завершиться ошибкой.
    unsafe { getuid() }
}

/// Base64 (RFC 4648, с `=`) — только для сравнения заголовка Basic.
fn base64(text: String) -> String {
    const ABC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in text.as_bytes().chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            out.push(if i <= chunk.len() { ABC[((n >> (18 - 6 * i)) & 63) as usize] as char } else { '=' });
        }
    }
    out
}

fn join(a: &str, b: &str) -> String {
    format!("{}/{}", a.trim_end_matches('/'), b.trim_start_matches('/'))
}

fn base_name(path: &str) -> &str {
    path.trim_end_matches('/').rsplit('/').next().unwrap_or("")
}

/// Абсолютный путь без `//` и `/` в конце; `.`/`..`/NUL — None.
fn normalize(path: &str) -> Option<String> {
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    if parts.iter().any(|p| *p == "." || *p == ".." || p.contains('\0')) {
        return None;
    }
    Some(format!("/{}", parts.join("/")))
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: &str = "/abc/host";

    fn decide(method: &str, path: &str, dest: Option<&str>, ow: Option<&str>) -> DavAction {
        dav_decide(method.into(), path.into(), dest.map(Into::into), ow.map(Into::into), P.into(), "/srv".into())
    }

    fn status(a: &DavAction) -> Option<u16> {
        match a {
            DavAction::Reply { status, .. } => Some(*status),
            _ => None,
        }
    }

    #[test]
    fn remote_path_stays_inside_root() {
        let r = |p: &str| dav_remote_path(P.into(), "/srv".into(), p.into());
        assert_eq!(r("/abc/host"), Some("/srv".into()));
        assert_eq!(r("/abc/host/"), Some("/srv".into()));
        assert_eq!(r("/abc/host/a//b/"), Some("/srv/a/b".into()));
        assert_eq!(r("/abc/hostile/a"), None, "граница префикса — `/`");
        assert_eq!(r("/abc/host/../x"), None);
        assert_eq!(r("/abc/host/a/./b"), None);
        assert_eq!(r("/abc/host/a\0b"), None);
        assert_eq!(r("/other/host/a"), None);
        assert_eq!(r(""), None);
        assert_eq!(dav_remote_path(P.into(), "/".into(), "/abc/host/etc".into()), Some("/etc".into()));
    }

    #[test]
    fn base64_matches_rfc4648() {
        assert_eq!(base64("".into()), "");
        assert_eq!(base64("f".into()), "Zg==");
        assert_eq!(base64("fo".into()), "Zm8=");
        assert_eq!(base64("foobar".into()), "Zm9vYmFy");
        assert_eq!(base64("relaya:pw".into()), "cmVsYXlhOnB3");
    }

    #[test]
    fn root_resolution() {
        let home = || "/home/u".to_string();
        assert_eq!(dav_resolve_root("".into(), home()), Ok("/home/u".into()));
        assert_eq!(dav_resolve_root(" ~ ".into(), home()), Ok("/home/u".into()));
        assert_eq!(dav_resolve_root("~/docs/".into(), home()), Ok("/home/u/docs".into()));
        assert_eq!(dav_resolve_root("var/www".into(), home()), Ok("/var/www".into()));
        assert_eq!(dav_resolve_root("/".into(), home()), Ok("/".into()));
        assert!(dav_resolve_root("/srv/../etc".into(), home()).is_err());
        assert!(dav_resolve_root("~/..".into(), home()).is_err());
        assert!(dav_root_needs_home("~/x".into()) && dav_root_needs_home("".into()));
        assert!(!dav_root_needs_home("/x".into()) && !dav_root_needs_home("~x".into()));
    }

    #[test]
    fn volume_names() {
        assert_eq!(dav_volume_name("web".into(), "/".into()), "web");
        assert_eq!(dav_volume_name("web".into(), "".into()), "web");
        assert_eq!(dav_volume_name("web".into(), "~".into()), "web · ~");
        assert_eq!(dav_volume_name("web".into(), "/var/www/".into()), "web · www");
        assert_eq!(dav_volume_name("a/b".into(), "/".into()), "a-b");
    }

    #[test]
    fn secrets_and_auth() {
        let s = dav_new_secrets("web".into());
        assert_ne!(s.password, dav_new_secrets("web".into()).password);
        assert!(s.prefix.ends_with("/web") && s.prefix.len() > 30);
        assert_eq!(s.password.len(), 64);
        let good = format!("Basic {}", base64(format!("relaya:{}", s.password)));
        assert!(dav_authorized(Some(good.clone()), s.password.clone()));
        assert!(!dav_authorized(None, s.password.clone()));
        assert!(!dav_authorized(Some(good[..good.len() - 1].into()), s.password.clone()));
        assert!(!dav_authorized(Some("Bearer x".into()), s.password.clone()));
        assert!(!dav_authorized(Some(good), "other".into()));
    }

    #[test]
    fn decisions() {
        assert_eq!(status(&decide("GET", "/zzz/host/a", None, None)), Some(404));
        assert_eq!(decide("OPTIONS", "/", None, None), DavAction::Options);
        assert_eq!(status(&decide("DELETE", P, None, None)), Some(403));
        assert_eq!(status(&decide("MOVE", P, Some("/abc/host/x"), None)), Some(403));
        assert_eq!(status(&decide("PUT", P, None, None)), Some(405));
        assert_eq!(status(&decide("BREW", "/abc/host/a", None, None)), Some(405));
        assert_eq!(decide("GET", "/abc/host/a", None, None), DavAction::Get { remote: "/srv/a".into(), junk: false });
        assert_eq!(
            decide("PUT", "/abc/host/d/._a", None, None),
            DavAction::Put { remote: "/srv/d/._a".into(), junk: true }
        );
        assert_eq!(decide("PROPFIND", P, None, None), DavAction::Propfind { remote: "/srv".into(), junk: false });
        assert_eq!(
            decide("DELETE", "/abc/host/.DS_Store", None, None),
            DavAction::Delete { remote: "/srv/.DS_Store".into(), junk: true }
        );
    }

    #[test]
    fn move_copy_decisions() {
        let t = |dest: Option<&str>, ow: Option<&str>| decide("MOVE", "/abc/host/a", dest, ow);
        assert_eq!(status(&t(None, None)), Some(400));
        assert_eq!(status(&t(Some("http://127.0.0.1:1/zzz/host/b"), None)), Some(400), "вне префикса");
        assert_eq!(status(&t(Some("http://127.0.0.1:1/abc/host/../../etc"), None)), Some(400));
        assert_eq!(status(&t(Some("http://127.0.0.1:1/abc/host/a"), None)), Some(403), "сам в себя");
        assert_eq!(status(&t(Some("http://127.0.0.1:1/abc/host/a/b"), None)), Some(403), "внутрь себя");
        assert_eq!(status(&t(Some("http://127.0.0.1:1/abc/host"), None)), Some(403), "на место корня");
        assert_eq!(
            t(Some("http://127.0.0.1:1/abc/host/ab%20c"), None),
            DavAction::Transfer {
                source: "/srv/a".into(),
                destination: "/srv/ab c".into(),
                is_move: true,
                overwrite: true,
                junk: false
            }
        );
        assert!(matches!(t(Some("/abc/host/ab"), Some("f")), DavAction::Transfer { overwrite: false, .. }));
        assert!(matches!(t(Some("/abc/host/ab"), Some("T")), DavAction::Transfer { overwrite: true, .. }));
        assert!(matches!(
            decide("COPY", "/abc/host/a", Some("/abc/host/b"), None),
            DavAction::Transfer { is_move: false, .. }
        ));
    }

    #[test]
    fn transfer_plans() {
        let p = |mv, ow, ex| dav_transfer_plan("/srv/a b".into(), "/srv/c".into(), mv, ow, ex);
        assert_eq!(p(true, false, true), DavTransferPlan::Reply { status: 412, reason: "Precondition Failed".into() });
        assert_eq!(
            p(true, false, false),
            DavTransferPlan::Run { command: "mv -- '/srv/a b' '/srv/c'".into(), status: 201, reason: "Created".into() }
        );
        assert_eq!(
            p(false, true, true),
            DavTransferPlan::Run {
                command: "{ ! test -d '/srv/c' || rm -rf -- '/srv/c'; } && cp -a -- '/srv/a b' '/srv/c'".into(),
                status: 204,
                reason: "No Content".into()
            }
        );
        assert_eq!(dav_delete_command("/srv/it's".into()), format!("rm -rf -- {}", shell_quote("/srv/it's")));
        assert_eq!(dav_exists_command("/x".into()), "test -e '/x' || test -L '/x'");
    }

    #[test]
    fn temp_files_are_private() {
        let a = dav_temp_file().unwrap();
        let b = dav_temp_file().unwrap();
        assert_ne!(a, b);
        let dir = std::path::Path::new(&a).parent().unwrap().to_path_buf();
        assert_eq!(dir, temp_dir());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        }
        dav_temp_cleanup().unwrap();
        assert!(!dir.exists());
        dav_temp_cleanup().unwrap();
    }
}
