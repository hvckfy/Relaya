//! Понятные объяснения ошибок ssh/sftp/git: «что случилось» и «что сделать» вместо сырого хвоста stderr.
//! Тексты — ключи локализации (русские строки), клиенты переводят их сами.

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshProblem {
    /// Что случилось — коротко.
    pub title: String,
    /// Что сделать.
    pub hint: String,
    /// Исходная строка из stderr, по которой узнали ошибку.
    pub detail: String,
}

/// Правила по порядку: первая подходящая подстрока (без учёта регистра) в любой строке вывода.
const RULES: &[(&[&str], &str, &str)] = &[
    (&["too many authentication failures"],
     "Сервер отклонил вход: ssh-agent предложил слишком много ключей",
     "Укажите для этого сервера один ключ: в ~/.ssh/config добавьте IdentityFile с нужным ключом и IdentitiesOnly yes."),
    (&["remote host identification has changed", "host key verification failed"],
     "Ключ сервера не совпадает с сохранённым",
     "Если сервер переустанавливали или сменили адрес — удалите старую запись: ssh-keygen -R <адрес>. Иначе это может быть подмена сервера."),
    (&["permission denied (publickey)"],
     "Сервер не принял ни один ключ",
     "Установите свой публичный ключ на сервер (Ключи → Установить на хост) или укажите в хосте нужный ключ."),
    (&["permission denied, please try again", "permission denied (password", "authentication failed"],
     "Неверный пароль или пользователь",
     "Проверьте имя пользователя и пароль; сохранённый пароль можно изменить в карточке хоста."),
    (&["permission denied"],
     "Нет доступа",
     "Сервер отказал во входе. Проверьте пользователя, ключ или пароль."),
    (&["could not resolve hostname", "name or service not known", "nodename nor servname", "no such host is known"],
     "Адрес сервера не найден",
     "Проверьте HostName на опечатки и подключение к сети или VPN."),
    (&["connection refused"],
     "Сервер отказал в подключении",
     "На этом адресе и порту SSH не принимает соединения: проверьте порт и что sshd запущен."),
    (&["connection timed out", "operation timed out", "timed out", "no route to host", "network is unreachable"],
     "Сервер не отвечает",
     "Проверьте адрес, сеть, VPN и файрвол; сервер может быть выключен."),
    (&["kex_exchange_identification", "connection reset by peer", "connection closed by remote host"],
     "Сервер оборвал соединение до входа",
     "Часто это защита от перебора (fail2ban, MaxStartups) после неудачных попыток — подождите минуту и попробуйте снова."),
    (&["no matching host key type", "no matching key exchange", "no matching cipher", "no matching mac"],
     "Сервер слишком старый: нет общего алгоритма шифрования",
     "Обновите сервер или разрешите для него старый алгоритм в ~/.ssh/config (HostKeyAlgorithms, KexAlgorithms)."),
    (&["unprotected private key file", "bad permissions"],
     "У файла ключа слишком открытые права",
     "Ключ должен быть доступен только вам: chmod 600 на файл ключа."),
    (&["incorrect passphrase", "bad passphrase"],
     "Неверный пароль ключа",
     "Введите правильную passphrase или сохраните её заново."),
    (&["repository not found", "does not appear to be a git repository", "project you were looking for could not be found"],
     "Репозиторий не найден",
     "Проверьте адрес репозитория и что у вашего ключа есть к нему доступ."),
    (&["could not read from remote repository"],
     "Нет доступа к репозиторию",
     "Сервер git не пустил по SSH: проверьте ключ (лучше указать его для сервера в ~/.ssh/config) и адрес репозитория."),
    (&["no such file", "not recognized as an internal or external command", "program not found", "cannot find the file"],
     "Не найдена программа",
     "Установите недостающую программу (ssh, git) и перезапустите Relaya."),
];

/// Объяснение ошибки по выводу ssh/sftp/git, если она известна.
#[uniffi::export]
pub fn ssh_explain(output: String) -> Option<SshProblem> {
    let lines: Vec<&str> = output.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    for (keys, title, hint) in RULES {
        for line in &lines {
            let lower = line.to_lowercase();
            if keys.iter().any(|k| lower.contains(k)) {
                return Some(SshProblem { title: (*title).into(), hint: (*hint).into(), detail: (*line).into() });
            }
        }
    }
    None
}

/// Главная строка ошибки, если объяснения нет: fatal:/error: важнее последней строки.
#[uniffi::export]
pub fn ssh_error_line(output: String) -> String {
    let lines: Vec<&str> = output.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    lines.iter().find(|l| l.starts_with("fatal:") || l.starts_with("error:")).or(lines.last())
        .map(|l| l.to_string()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explains_common_failures() {
        let git = "Received disconnect from 1.2.3.4 port 22:2: Too many authentication failures\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.";
        let p = ssh_explain(git.into()).unwrap();
        assert!(p.title.contains("слишком много ключей"));
        assert!(p.detail.contains("Too many authentication failures"));
        assert!(ssh_explain("ssh: Could not resolve hostname foo: nodename nor servname provided".into()).unwrap().title.contains("не найден"));
        assert!(ssh_explain("git@x: Permission denied (publickey).".into()).unwrap().title.contains("ни один ключ"));
        assert!(ssh_explain("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@".into()).unwrap().title.contains("не совпадает"));
        assert!(ssh_explain("all fine".into()).is_none());
        assert_eq!(ssh_error_line("x\nfatal: bad\nand the repository exists.".into()), "fatal: bad");
    }
}
