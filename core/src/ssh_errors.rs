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
    (&["permission denied", "отказано в доступе", "доступ запрещен", "доступ запрещён"],
     "Нет доступа",
     "Сервер отказал во входе. Проверьте пользователя, ключ или пароль."),
    (&["could not resolve hostname", "name or service not known", "nodename nor servname", "no such host is known", "этот хост неизвестен", "неизвестный хост"],
     "Адрес сервера не найден",
     "Проверьте HostName на опечатки и подключение к сети или VPN."),
    (&["connection refused", "отверг запрос на подключение", "в подключении отказано"],
     "Сервер отказал в подключении",
     "На этом адресе и порту SSH не принимает соединения: проверьте порт и что sshd запущен."),
    (&["connection timed out", "operation timed out", "timed out", "no route to host", "network is unreachable", "попытка установить соединение была безуспешной", "превышен таймаут", "сеть недоступна"],
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
    (&["repository not found", "does not appear to be a git repository", "project you were looking for could not be found", "репозиторий не найден", "не похоже на git репозиторий", "не является git репозиторием"],
     "Репозиторий не найден",
     "Проверьте адрес репозитория и что у вашего ключа есть к нему доступ."),
    (&["could not read from remote repository", "не удалось прочитать из внешнего репозитория"],
     "Нет доступа к репозиторию",
     "Сервер git не пустил по SSH: проверьте ключ (лучше указать его для сервера в ~/.ssh/config) и адрес репозитория."),
    // sftp/scp: файла на сервере нет — раньше это ловило правило «не найдена программа».
    (&["couldn't stat remote file", "can't open remote file", "remote open", "couldn't open remote"],
     "Файла на сервере нет",
     "Проверьте путь на сервере: файл могли удалить, переименовать или он лежит в другой папке."),
    (&["command not found", "createprocess", "not recognized as an internal or external command", "program not found", "cannot find the file", "не является внутренней или внешней", "не удается найти указанный файл", "не удаётся найти указанный файл",
        "команда не найдена"],
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

/// Протокол удалённого рабочего стола для `remote_explain`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteProtocol { Rdp, Vnc }

/// RDP: тексты RDPKit (Mac), IronRDP (`RemoteClose`) и коды Windows. Порядок важен: частные правила раньше общих.
const RDP_RULES: &[(&[&str], &str, &str)] = &[
    (&["account_locked", "account locked", "account is locked", "account_disabled", "account disabled", "учётная запись заблокирована", "учетная запись заблокирована"],
     "Учётная запись заблокирована или отключена",
     "Обратитесь к администратору сервера или подождите, пока блокировка снимется сама."),
    (&["password_expired", "password expired", "password_must_change", "must change password", "срок действия пароля истёк", "срок действия пароля истек"],
     "Пароль истёк — сервер требует сменить его",
     "Войдите на сервер другим способом (консоль, веб-доступ) и смените пароль, затем подключитесь снова."),
    (&["logon_failure", "logon failure", "sec_e_logon_denied", "status_logon_failure", "wrong password", "invalid credentials",
       "authentication failed", "credssp", "неверное имя пользователя или пароль"],
     "Неверный логин или пароль",
     "Проверьте имя пользователя, домен (DOMAIN\\user или user@domain) и пароль."),
    (&["hybrid_required_by_server", "nla required", "requires network level authentication", "ssl_required_by_server"],
     "Сервер требует проверку подлинности на уровне сети (NLA)",
     "Укажите логин и пароль в настройках подключения: без них сервер не пускает."),
    (&["ssl_not_allowed_by_server", "hybrid_not_allowed", "nla is disabled", "ssl_cert_not_on_server", "inconsistent_flags"],
     "Сервер не принимает проверку подлинности на уровне сети (NLA)",
     "На сервере выключен NLA или нет сертификата для TLS: включите «Разрешить подключения только с NLA» или попросите администратора."),
    (&["certificate not accepted", "certrejected", "certificate changed", "certificate has changed", "fingerprint mismatch"],
     "Сертификат сервера изменился или не принят",
     "Если сервер переустанавливали или сменили сертификат — примите новый отпечаток. Иначе это может быть подмена сервера."),
    (&["session limit", "too many sessions", "another user is connected", "server_insufficient_privileges", "connection limit",
       "another user", "maximum number of connections"],
     "Сервер занят: достигнут лимит сеансов",
     "Попросите другого пользователя выйти или завершите старый сеанс; на обычной Windows разрешён один удалённый сеанс."),
    (&["licens", "no licenses available", "rds licensing", "лицензи"],
     "Нет лицензии служб удалённых рабочих столов",
     "На сервере RDS истёк льготный период или нет лицензий — нужен администратор сервера."),
    (&["connection refused", "отверг запрос на подключение", "в подключении отказано"],
     "Сервер отказал в подключении",
     "На этом адресе и порту RDP не принимает соединения: проверьте порт (обычно 3389), что удалённый рабочий стол включён и файрвол."),
    (&["timed out", "timeout", "no route to host", "network is unreachable", "попытка установить соединение была безуспешной",
       "address not found", "could not resolve", "no such host"],
     "Сервер RDP не отвечает",
     "Проверьте адрес, сеть, VPN и файрвол (порт 3389); сервер может быть выключен."),
];

/// VNC: тексты RoyalVNC (Mac), vnc-rs и RFB.
const VNC_RULES: &[(&[&str], &str, &str)] = &[
    (&["too many", "too many authentication failures", "too many security failures", "blacklist", "temporarily blocked"],
     "Сервер VNC временно блокирует вход",
     "Было слишком много неудачных попыток — подождите несколько минут и попробуйте снова с правильным паролем."),
    (&["password too long", "longer than 8", "8 characters", "truncated to 8"],
     "Пароль VNC длиннее 8 символов",
     "Классический VNC учитывает только первые 8 символов пароля: задайте на сервере пароль не длиннее 8 символов."),
    (&["apple remote desktop", "ard authentication", "(ard)", "diffie-hellman", "macos user", "security type 30"],
     "Нужен логин и пароль пользователя macOS",
     "Этот Mac принимает вход учётной записью macOS (Apple Remote Desktop): укажите имя пользователя и пароль Mac, а не VNC-пароль."),
    (&["vencrypt", "security type 19", "unsupported security", "no supported security", "unsupported authentication", "unknown security type",
       "tls is required", "ra2"],
     "Неподдерживаемый тип аутентификации или шифрования",
     "Сервер требует VeNCrypt/TLS или другой способ входа, который пока не поддерживается. Включите на сервере обычный VNC-пароль."),
    (&["authentication failed", "auth failed", "wrong password", "invalid password", "password check failed", "неверный пароль"],
     "Неверный пароль VNC",
     "Проверьте пароль VNC (не пароль пользователя системы, если сервер не просит логин)."),
    (&["authentication required", "password required", "no password", "requires a password"],
     "Сервер требует пароль",
     "Укажите пароль VNC в настройках подключения."),
    (&["connection refused", "отверг запрос на подключение", "в подключении отказано"],
     "Сервер отказал в подключении",
     "На этом адресе и порту VNC не принимает соединения: проверьте порт (обычно 5900, дисплей :1 — 5901) и что общий экран включён."),
    (&["timed out", "timeout", "no route to host", "network is unreachable", "попытка установить соединение была безуспешной",
       "address not found", "could not resolve", "no such host"],
     "Сервер VNC не отвечает",
     "Проверьте адрес, сеть, VPN и файрвол (порт 5900); сервер может быть выключен."),
];

fn explain_with(rules: &[(&[&str], &str, &str)], output: &str) -> Option<SshProblem> {
    let lines: Vec<&str> = output.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    for (keys, title, hint) in rules {
        for line in &lines {
            let lower = line.to_lowercase();
            if keys.iter().any(|k| lower.contains(k)) {
                return Some(SshProblem { title: (*title).into(), hint: (*hint).into(), detail: (*line).into() });
            }
        }
    }
    None
}

/// Объяснение ошибки RDP или VNC (RDPKit, RoyalVNC, IronRDP, текст `RemoteClose`), если она известна.
/// Как и у `ssh_explain`, `title` и `hint` — ключи локализации.
#[uniffi::export]
pub fn remote_explain(protocol: RemoteProtocol, message: String) -> Option<SshProblem> {
    match protocol { RemoteProtocol::Rdp => explain_with(RDP_RULES, &message), RemoteProtocol::Vnc => explain_with(VNC_RULES, &message) }
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
        let ru = "git@gitlab.com: Permission denied (publickey).\nfatal: Не удалось прочитать из внешнего репозитория.\n\nУдостоверьтесь, что у вас есть необходимые права доступа\nи репозиторий существует.";
        assert!(ssh_explain(ru.into()).unwrap().title.contains("ни один ключ"));
        assert!(ssh_explain("fatal: Не удалось прочитать из внешнего репозитория.".into()).unwrap().title.contains("к репозиторию"));
        assert!(ssh_explain("ssh: Could not resolve hostname x: Этот хост неизвестен.".into()).unwrap().title.contains("не найден"));
        assert!(ssh_explain("connect to host x port 22: Подключение не установлено, т.к. конечный компьютер отверг запрос на подключение.".into()).unwrap().title.contains("отказал в подключении"));
        assert!(ssh_explain("\"ssh\" не является внутренней или внешней командой".into()).unwrap().title.contains("программа"));
        assert!(ssh_explain("fatal: «x» не похоже на git репозиторий".into()).unwrap().title.contains("не найден"));
        assert!(ssh_explain("Couldn't stat remote file: No such file or directory".into()).unwrap().title.contains("Файла на сервере нет"));
        assert!(ssh_explain("Warning: Identity file ~/.ssh/x not accessible: No such file or directory.".into()).is_none());
        assert!(ssh_explain("rm: cannot remove 'a': No such file or directory".into()).is_none());
        assert!(ssh_explain("zsh: command not found: ssh".into()).unwrap().title.contains("программа"));
        assert_eq!(ssh_error_line("x\nfatal: bad\nand the repository exists.".into()), "fatal: bad");
    }

    #[test]
    fn explains_remote_desktop_failures() {
        let rdp = |m: &str| remote_explain(RemoteProtocol::Rdp, m.into()).map(|p| p.title);
        let vnc = |m: &str| remote_explain(RemoteProtocol::Vnc, m.into()).map(|p| p.title);
        assert_eq!(rdp("CredSSP: SEC_E_LOGON_DENIED").as_deref(), Some("Неверный логин или пароль"));
        assert_eq!(rdp("STATUS_PASSWORD_EXPIRED").as_deref(), Some("Пароль истёк — сервер требует сменить его"));
        assert_eq!(rdp("STATUS_ACCOUNT_LOCKED_OUT").as_deref(), Some("Учётная запись заблокирована или отключена"));
        assert_eq!(rdp("negotiation failure: HYBRID_REQUIRED_BY_SERVER").as_deref(), Some("Сервер требует проверку подлинности на уровне сети (NLA)"));
        assert_eq!(rdp("SSL_NOT_ALLOWED_BY_SERVER").as_deref(), Some("Сервер не принимает проверку подлинности на уровне сети (NLA)"));
        assert_eq!(rdp("certificate not accepted").as_deref(), Some("Сертификат сервера изменился или не принят"));
        assert!(rdp("The remote session was disconnected because there are no Remote Desktop License Servers available").unwrap().contains("лицензии"));
        assert_eq!(rdp("Connection refused (os error 61)").as_deref(), Some("Сервер отказал в подключении"));
        assert_eq!(rdp("connection timed out").as_deref(), Some("Сервер RDP не отвечает"));
        assert_eq!(vnc("Authentication failed").as_deref(), Some("Неверный пароль VNC"));
        assert_eq!(vnc("Too many authentication failures").as_deref(), Some("Сервер VNC временно блокирует вход"));
        assert_eq!(vnc("Unsupported security type: VeNCrypt").as_deref(), Some("Неподдерживаемый тип аутентификации или шифрования"));
        assert_eq!(vnc("Server requires Apple Remote Desktop authentication").as_deref(), Some("Нужен логин и пароль пользователя macOS"));
        assert!(vnc("all fine").is_none());
        assert!(rdp("").is_none());
    }
}
