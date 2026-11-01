//! Мастер «Настроить вход по ключу»: удалённая установка публичного ключа и проверочный вход (как KeyInstaller.swift).
//! Секреты сюда не попадают: пароль сервера клиенты отдают ssh через askpass, ключ — через stdin.

/// Удалённый скрипт установки ключа (POSIX sh, работает и в busybox). Ключ — одной строкой в stdin; дописывается в
/// `~/.ssh/authorized_keys` без дублей (права 700/600), у root при наличии Dropbear (OpenWrt) — ещё в
/// `/etc/dropbear/authorized_keys`: Dropbear читает ключи root оттуда.
#[uniffi::export]
pub fn key_install_remote_command() -> String {
    r#"sh -c 'umask 077; read -r k || exit 1; add() { mkdir -p "${1%/*}" && touch "$1" && chmod 600 "$1" && { grep -qxF "$k" "$1" 2>/dev/null || printf "%s\n" "$k" >> "$1"; }; }; add "$HOME/.ssh/authorized_keys" && chmod 700 "$HOME/.ssh" || exit 1; if [ "$(id -u)" = 0 ] && [ -d /etc/dropbear ]; then add /etc/dropbear/authorized_keys || exit 1; fi'"#.into()
}

/// Аргументы ssh для установки ключа (без пути к ssh): известный ключ сервера обязателен, один запрос пароля;
/// `password` — вход по паролю через askpass без перебора ключей агента, иначе BatchMode. Затем алиас и скрипт.
#[uniffi::export]
pub fn key_install_ssh_args(alias: String, password: bool) -> Vec<String> {
    let mut args: Vec<String> =
        ["-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", "-o", "NumberOfPasswordPrompts=1"]
            .map(String::from)
            .into();
    if password {
        args.extend(crate::models::password_only_options());
    } else {
        args.extend(["-o".into(), "BatchMode=yes".into()]);
    }
    args.push(alias);
    args.push(key_install_remote_command());
    args
}

/// Аргументы ssh для проверочного входа только этим ключом, без пароля и агента: `… -i key alias true`.
#[uniffi::export]
pub fn key_verify_ssh_args(alias: String, key_path: String) -> Vec<String> {
    let mut args: Vec<String> = [
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "PasswordAuthentication=no",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ConnectTimeout=15",
        "-i",
    ]
    .map(String::from)
    .into();
    args.extend([key_path, alias, "true".into()]);
    args
}

/// Подсказка, если проверочный вход отклонён: ключ на сервере, но sshd его не принимает. Ключ локализации тот же,
/// что у Mac: начинается с «. » — клиент дописывает его к тексту ошибки входа.
#[uniffi::export]
pub fn key_verify_hint(stderr: String) -> Option<String> {
    stderr.contains("Permission denied").then(|| {
        ". Ключ на сервер добавлен, но сервер его не принимает — проверьте права (~/.ssh 700, authorized_keys 600, \
         домашний каталог без записи для группы) и не отключён ли вход по ключу в настройках sshd."
            .into()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_and_verify_args() {
        let cmd = key_install_remote_command();
        assert!(cmd.starts_with("sh -c 'umask 077; read -r k") && cmd.contains("/etc/dropbear/authorized_keys"));
        assert!(cmd.contains(r#"grep -qxF "$k""#), "без дублей");
        let pw = key_install_ssh_args("web".into(), true);
        assert!(pw.contains(&"PubkeyAuthentication=no".to_string()) && !pw.contains(&"BatchMode=yes".to_string()));
        assert_eq!(&pw[pw.len() - 2..], &["web".to_string(), cmd.clone()]);
        let batch = key_install_ssh_args("web".into(), false);
        assert!(
            batch.contains(&"BatchMode=yes".to_string()) && batch.contains(&"NumberOfPasswordPrompts=1".to_string())
        );
        let v = key_verify_ssh_args("web".into(), "/home/u/.ssh/id".into());
        assert_eq!(&v[v.len() - 4..], &["-i", "/home/u/.ssh/id", "web", "true"].map(String::from));
        assert!(v.contains(&"PasswordAuthentication=no".to_string()) && v.contains(&"IdentitiesOnly=yes".to_string()));
        assert!(key_verify_hint("git@x: Permission denied (publickey).".into())
            .unwrap()
            .contains("authorized_keys 600"));
        assert!(key_verify_hint("Connection refused".into()).is_none());
    }
}
