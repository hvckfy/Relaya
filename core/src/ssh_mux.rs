//! Одно ssh-соединение на хост для служебных операций (П-9): SFTP, диск, статистика, карточка хоста. Интерактивные
//! терминалы идут своими соединениями. Mac и Linux — ControlMaster с сокетом в приватном каталоге; Windows — один
//! долгоживущий `sftp -b -`, команды которого строятся здесь же (`sftp_batch_path`).
//!
//! Требования аудита безопасности: каталог сокетов — настоящий каталог (не ссылка) текущего пользователя с режимом
//! ровно 0700, иначе мультиплекс выключается; на master нет пересылок и агента; хосты, чей конфиг запускает команды
//! (`config_runs_commands`), не мультиплексируются — это решает клиент до вызова.

use sha2::{Digest, Sha256};

use crate::error::CoreError;

/// Сколько master живёт без каналов. Клиент к тому же закрывает его явно (`ssh_mux_exit_args`) при закрытии хоста,
/// выходе, блокировке экрана и сне.
pub const MUX_PERSIST_SECONDS: u32 = 60;

/// Приватный каталог сокетов `<base>/relaya-cm-<uid>`: создаётся с 0700; уже существующий принимается, только если
/// это каталог (не символическая ссылка) этого пользователя с режимом ровно 0700. Иначе ошибка — клиент работает
/// без мультиплекса. `base` — `$TMPDIR` на Mac, `$XDG_RUNTIME_DIR` (или свой 0700-каталог) на Linux.
#[uniffi::export]
pub fn ssh_mux_dir(base: String) -> Result<String, CoreError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
        if base.trim().is_empty() {
            return Err(CoreError::InvalidValue("base".into()));
        }
        let uid = unsafe { libc_getuid() };
        let dir = std::path::Path::new(&base).join(format!("relaya-cm-{uid}"));
        match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e.into()),
        }
        // symlink_metadata: ссылку не разыменовываем — подменённый каталог не примем.
        let meta = std::fs::symlink_metadata(&dir)?;
        if !meta.file_type().is_dir() || meta.uid() != uid || meta.permissions().mode() & 0o777 != 0o700 {
            return Err(CoreError::Io(format!("{}: unsafe control directory", dir.display())));
        }
        Ok(dir.to_string_lossy().into_owned())
    }
    #[cfg(not(unix))]
    {
        let _ = base;
        Err(CoreError::InvalidValue("ControlMaster is not used on Windows".into()))
    }
}

/// Путь сокета для хоста: короткий хеш алиаса (длина пути сокета ограничена ~104 байтами).
#[uniffi::export]
pub fn ssh_mux_control_path(dir: String, alias: String) -> String {
    let hash = Sha256::digest(alias.as_bytes());
    let name: String = hash.iter().take(8).map(|b| format!("{b:02x}")).collect();
    std::path::Path::new(&dir).join(name).to_string_lossy().into_owned()
}

/// Параметры ssh для служебного вызова через master: без пересылок, агента и X11.
#[uniffi::export]
pub fn ssh_mux_options(control_path: String) -> Vec<String> {
    [
        "ControlMaster=auto".to_string(),
        format!("ControlPath={control_path}"),
        format!("ControlPersist={MUX_PERSIST_SECONDS}"),
        "ClearAllForwardings=yes".into(),
        "ForwardAgent=no".into(),
        "ForwardX11=no".into(),
    ]
    .into_iter()
    .flat_map(|o| ["-o".to_string(), o])
    .collect()
}

/// Аргументы ssh, закрывающие master хоста: `ssh <это>`.
#[uniffi::export]
pub fn ssh_mux_exit_args(control_path: String, alias: String) -> Vec<String> {
    vec!["-o".into(), format!("ControlPath={control_path}"), "-O".into(), "exit".into(), alias]
}

/// Путь для команды `sftp -b -` по грамматике sftp, а не shell: в двойных кавычках, `\`, `"` и знаки шаблона
/// (`*`, `?`, `[`, `]`) экранированы обратной чертой, чтобы путь не раскрылся в чужие файлы. Перевод строки, `\r`,
/// NUL и другие управляющие символы — ошибка: иначе имя файла вписало бы лишнюю команду (put, rm).
#[uniffi::export]
pub fn sftp_batch_path(path: String) -> Result<String, CoreError> {
    if path.is_empty() || path.chars().any(|c| c.is_control()) {
        return Err(CoreError::InvalidValue(path));
    }
    let mut out = String::with_capacity(path.len() + 2);
    out.push('"');
    for c in path.chars() {
        if matches!(c, '\\' | '"' | '*' | '?' | '[' | ']') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    Ok(out)
}

#[cfg(unix)]
extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batch_paths_are_quoted_or_refused() {
        assert_eq!(sftp_batch_path("/home/me/a b.txt".into()).unwrap(), "\"/home/me/a b.txt\"");
        assert_eq!(sftp_batch_path("/x/*.log".into()).unwrap(), "\"/x/\\*.log\"");
        assert_eq!(sftp_batch_path("/x/a?[1]".into()).unwrap(), "\"/x/a\\?\\[1\\]\"");
        assert_eq!(sftp_batch_path("/x/say \"hi\"".into()).unwrap(), "\"/x/say \\\"hi\\\"\"");
        assert_eq!(sftp_batch_path("C:\\a".into()).unwrap(), "\"C:\\\\a\"");
        for bad in ["", "/x\nrm -rf /", "/x\r", "/x\0", "/x\u{1b}[31m", "/x\u{7f}"] {
            assert!(sftp_batch_path(bad.into()).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn options_have_no_forwarding() {
        let o = ssh_mux_options("/tmp/s".into());
        assert!(o.contains(&"ControlPath=/tmp/s".to_string()));
        assert!(o.contains(&"ClearAllForwardings=yes".to_string()));
        assert!(o.contains(&"ForwardAgent=no".to_string()));
        assert_eq!(ssh_mux_exit_args("/tmp/s".into(), "web".into()), ["-o", "ControlPath=/tmp/s", "-O", "exit", "web"]);
        assert_eq!(ssh_mux_control_path("/d".into(), "web".into()).len(), "/d/".len() + 16);
    }

    #[cfg(unix)]
    #[test]
    fn control_dir_is_private_and_not_a_link() {
        use std::os::unix::fs::PermissionsExt;
        let base = std::env::temp_dir().join(format!("relaya-mux-test-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&base).unwrap();
        let dir = ssh_mux_dir(base.to_string_lossy().into()).unwrap();
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        // Ослабленные права — отказ.
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(ssh_mux_dir(base.to_string_lossy().into()).is_err());
        // Ссылка вместо каталога — отказ.
        let base2 = base.join("b2");
        std::fs::create_dir_all(&base2).unwrap();
        let uid = unsafe { libc_getuid() };
        std::os::unix::fs::symlink(&base, base2.join(format!("relaya-cm-{uid}"))).unwrap();
        assert!(ssh_mux_dir(base2.to_string_lossy().into()).is_err());
        std::fs::remove_dir_all(&base).ok();
    }
}
