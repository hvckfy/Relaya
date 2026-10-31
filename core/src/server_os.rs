//! ОС сервера: определение по `/etc/os-release`/`uname`/приветствию, менеджер пакетов, готовые команды.
//! Подписи (`title` действий) — ключи локализации на русском; клиенты переводят их сами.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ServerOs {
    Ubuntu, Debian, Raspbian, Fedora, Centos, Rhel, Rocky, Alma, Alpine, Arch, Opensuse,
    Openwrt, Linux, Macos, Freebsd, Windows,
    Mint, Popos, Elementary, Zorin, Kali, Proxmox, Manjaro, Endeavouros, Gentoo, Nixos, Void, Openbsd,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PackageManager { Apt, Dnf, Yum, Apk, Pacman, Zypper, Opkg, Brew, Pkg }

/// Готовая команда для меню «Действия»: вставляется в терминал без Enter.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OsAction {
    /// Ключ локализации (русская строка).
    pub title: String,
    pub command: String,
    pub needs_root: bool,
}

const ALL: [(ServerOs, &str, &str); 28] = [
    (ServerOs::Ubuntu, "ubuntu", "Ubuntu"), (ServerOs::Debian, "debian", "Debian"),
    (ServerOs::Raspbian, "raspbian", "Raspberry Pi OS"), (ServerOs::Fedora, "fedora", "Fedora"),
    (ServerOs::Centos, "centos", "CentOS"), (ServerOs::Rhel, "rhel", "Red Hat"),
    (ServerOs::Rocky, "rocky", "Rocky Linux"), (ServerOs::Alma, "alma", "AlmaLinux"),
    (ServerOs::Alpine, "alpine", "Alpine"), (ServerOs::Arch, "arch", "Arch Linux"),
    (ServerOs::Opensuse, "opensuse", "openSUSE"), (ServerOs::Openwrt, "openwrt", "OpenWrt"),
    (ServerOs::Linux, "linux", "Linux"), (ServerOs::Macos, "macos", "macOS"),
    (ServerOs::Freebsd, "freebsd", "FreeBSD"), (ServerOs::Windows, "windows", "Windows"),
    (ServerOs::Mint, "mint", "Linux Mint"), (ServerOs::Popos, "popos", "Pop!_OS"),
    (ServerOs::Elementary, "elementary", "elementary OS"), (ServerOs::Zorin, "zorin", "Zorin OS"),
    (ServerOs::Kali, "kali", "Kali Linux"), (ServerOs::Proxmox, "proxmox", "Proxmox VE"),
    (ServerOs::Manjaro, "manjaro", "Manjaro"), (ServerOs::Endeavouros, "endeavouros", "EndeavourOS"),
    (ServerOs::Gentoo, "gentoo", "Gentoo"), (ServerOs::Nixos, "nixos", "NixOS"),
    (ServerOs::Void, "void", "Void Linux"), (ServerOs::Openbsd, "openbsd", "OpenBSD"),
];

impl ServerOs {
    /// Значение для `# relaya: os=…` (как rawValue в Swift).
    pub fn raw(self) -> &'static str { ALL.iter().find(|x| x.0 == self).unwrap().1 }
    pub fn title(self) -> &'static str { ALL.iter().find(|x| x.0 == self).unwrap().2 }
    pub fn from_raw(s: &str) -> Option<ServerOs> { ALL.iter().find(|x| x.1 == s).map(|x| x.0) }

    pub fn package_manager(self) -> Option<PackageManager> {
        use ServerOs::*;
        Some(match self {
            Ubuntu | Debian | Raspbian | Mint | Popos | Elementary | Zorin | Kali | Proxmox => PackageManager::Apt,
            Manjaro | Endeavouros | Arch => PackageManager::Pacman,
            Fedora | Rocky | Alma | Rhel => PackageManager::Dnf,
            Centos => PackageManager::Yum,
            Alpine => PackageManager::Apk,
            Opensuse => PackageManager::Zypper,
            Openwrt => PackageManager::Opkg,
            Macos => PackageManager::Brew,
            Freebsd => PackageManager::Pkg,
            Linux | Windows | Gentoo | Nixos | Void | Openbsd => return None,
        })
    }

    fn from_id(id: &str) -> Option<ServerOs> {
        use ServerOs::*;
        Some(match id {
            "ubuntu" => Ubuntu, "linuxmint" => Mint, "pop" => Popos, "elementary" => Elementary, "zorin" => Zorin,
            "kali" => Kali, "proxmox" => Proxmox, "manjaro" | "manjaro-arm" => Manjaro, "endeavouros" => Endeavouros,
            "gentoo" => Gentoo, "nixos" => Nixos, "void" => Void, "debian" => Debian, "raspbian" => Raspbian,
            "fedora" => Fedora, "centos" => Centos, "rhel" => Rhel, "rocky" => Rocky, "almalinux" => Alma,
            "alpine" => Alpine, "arch" => Arch,
            "opensuse" | "opensuse-leap" | "opensuse-tumbleweed" | "sles" | "suse" => Opensuse,
            "openwrt" => Openwrt,
            _ => return None,
        })
    }
}

#[uniffi::export]
pub fn os_raw(os: ServerOs) -> String { os.raw().into() }
#[uniffi::export]
pub fn os_title(os: ServerOs) -> String { os.title().into() }
#[uniffi::export]
pub fn os_from_raw(raw: String) -> Option<ServerOs> { ServerOs::from_raw(&raw) }
#[uniffi::export]
pub fn os_all() -> Vec<ServerOs> { ALL.iter().map(|x| x.0).collect() }
#[uniffi::export]
pub fn os_package_manager(os: ServerOs) -> Option<PackageManager> { os.package_manager() }

/// Команда фоновой проверки: POSIX sh; на Windows вернёт ошибку — это тоже ответ.
#[uniffi::export]
pub fn os_probe_command() -> String {
    "uname -s 2>/dev/null; cat /etc/os-release 2>/dev/null; [ -f /etc/openwrt_release ] && echo ID=openwrt; [ -d /etc/pve ] && echo ID=proxmox; true".into()
}

fn unquote(s: &str) -> &str { s.trim_matches(|c| c == '"' || c == '\'') }

/// Разбор вывода `os_probe_command`.
#[uniffi::export]
pub fn os_parse_probe(probe: String) -> Option<ServerOs> {
    let mut id: Option<String> = None;
    let mut like: Vec<String> = Vec::new();
    let mut uname: Option<String> = None;
    for raw in probe.lines() {
        let line = raw.trim();
        if let Some(v) = line.strip_prefix("ID=") {
            // ID=openwrt/proxmox печатаются последними и важнее os-release.
            id = Some(unquote(v).to_lowercase());
        } else if let Some(v) = line.strip_prefix("ID_LIKE=") {
            like = unquote(v).to_lowercase().split(' ').map(str::to_string).collect();
        } else if uname.is_none() && !line.contains('=') {
            uname = Some(line.to_lowercase());
        }
    }
    if let Some(os) = id.as_deref().and_then(ServerOs::from_id) { return Some(os); }
    if let Some(os) = like.iter().find_map(|l| ServerOs::from_id(l)) { return Some(os); }
    match uname.as_deref() {
        Some("darwin") => return Some(ServerOs::Macos),
        Some("freebsd") => return Some(ServerOs::Freebsd),
        Some("openbsd") => return Some(ServerOs::Openbsd),
        Some("linux") => return Some(ServerOs::Linux),
        Some(u) if u.contains("mingw") || u.contains("cygwin") || u.contains("msys") => return Some(ServerOs::Windows),
        _ => {}
    }
    if probe.contains("is not recognized as an internal or external command") { return Some(ServerOs::Windows); }
    None
}

/// Догадка по приветствию сервера в терминале.
#[uniffi::export]
pub fn os_guess_from_banner(text: String) -> Option<ServerOs> {
    use ServerOs::*;
    let checks = [
        ("OpenWrt", Openwrt), ("Raspbian", Raspbian), ("Linux Mint", Mint), ("Pop!_OS", Popos), ("Kali", Kali),
        ("pve-manager", Proxmox), ("Manjaro", Manjaro), ("Ubuntu", Ubuntu), ("Debian GNU/Linux", Debian),
        ("Alpine", Alpine), ("Fedora", Fedora), ("CentOS", Centos), ("Rocky Linux", Rocky), ("AlmaLinux", Alma),
        ("Red Hat Enterprise", Rhel), ("Arch Linux", Arch), ("openSUSE", Opensuse), ("FreeBSD", Freebsd),
        ("Microsoft Windows", Windows),
    ];
    checks.iter().find(|c| text.contains(c.0)).map(|c| c.1)
}

fn act(title: &str, command: &str, root: bool) -> OsAction {
    OsAction { title: title.into(), command: command.into(), needs_root: root }
}

/// Действия для меню: пакеты и сведения о системе.
#[uniffi::export]
pub fn os_actions(os: ServerOs) -> Vec<OsAction> {
    let mut list = Vec::new();
    match os.package_manager() {
        Some(PackageManager::Apt) => list.extend([act("Обновить пакеты", "sudo apt update && sudo apt upgrade", true),
                                                  act("Установить пакет…", "sudo apt install ", true),
                                                  act("Удалить ненужные пакеты", "sudo apt autoremove", true)]),
        Some(PackageManager::Dnf) => list.extend([act("Обновить пакеты", "sudo dnf upgrade", true),
                                                  act("Установить пакет…", "sudo dnf install ", true)]),
        Some(PackageManager::Yum) => list.extend([act("Обновить пакеты", "sudo yum update", true),
                                                  act("Установить пакет…", "sudo yum install ", true)]),
        Some(PackageManager::Apk) => list.extend([act("Обновить пакеты", "apk update && apk upgrade", true),
                                                  act("Установить пакет…", "apk add ", true)]),
        Some(PackageManager::Pacman) => list.extend([act("Обновить пакеты", "sudo pacman -Syu", true),
                                                     act("Установить пакет…", "sudo pacman -S ", true)]),
        Some(PackageManager::Zypper) => list.extend([act("Обновить пакеты", "sudo zypper refresh && sudo zypper update", true),
                                                     act("Установить пакет…", "sudo zypper install ", true)]),
        Some(PackageManager::Opkg) => list.extend([act("Обновить список пакетов", "opkg update", false),
                                                   act("Обновляемые пакеты", "opkg list-upgradable", false),
                                                   act("Установить пакет…", "opkg install ", false)]),
        Some(PackageManager::Brew) => list.extend([act("Обновить пакеты", "brew update && brew upgrade", false),
                                                   act("Установить пакет…", "brew install ", false)]),
        Some(PackageManager::Pkg) => list.extend([act("Обновить пакеты", "sudo pkg update && sudo pkg upgrade", true),
                                                  act("Установить пакет…", "sudo pkg install ", true)]),
        None => {}
    }
    match os {
        ServerOs::Openwrt => list.extend([
            act("Сведения о системе", "ubus call system board", false),
            act("Сетевые интерфейсы", "ifstatus wan; ip -br addr", false),
            act("Wi-Fi клиенты", "iwinfo; for i in $(iwinfo | awk '/ESSID/{print $1}'); do iwinfo $i assoclist; done", false),
            act("Журнал", "logread | tail -n 100", false),
            act("Перезапустить сеть", "/etc/init.d/network restart", false)]),
        ServerOs::Macos => list.extend([act("Сведения о системе", "sw_vers; uname -m; uptime", false),
                                        act("Место на диске", "df -h /", false),
                                        act("Нагрузка", "top -l 1 -n 10 -o cpu", false)]),
        ServerOs::Freebsd => list.extend([act("Сведения о системе", "freebsd-version; uname -a; uptime", false),
                                          act("Место на диске", "df -h", false),
                                          act("Сервисы", "service -e", false)]),
        ServerOs::Windows => list.extend([act("Сведения о системе", "systeminfo", false),
                                          act("Место на диске", "wmic logicaldisk get caption,freespace,size", false),
                                          act("Процессы", "tasklist", false)]),
        _ => list.extend([act("Сведения о системе", "cat /etc/os-release; uname -a; uptime", false),
                          act("Место на диске", "df -h", false),
                          act("Память", "free -h", false),
                          act("Нагрузка", "top -b -n 1 | head -n 20", false),
                          act("Упавшие сервисы", "systemctl --failed", false),
                          act("Журнал (последние ошибки)", "sudo journalctl -p err -n 50 --no-pager", true)]),
    }
    list
}

/// Включить/отключить вход по паролю на сервере (показывается и выполняется только по подтверждению).
#[uniffi::export]
pub fn os_password_login_command(os: ServerOs, enabled: bool) -> String {
    if os == ServerOs::Openwrt {
        let v = if enabled { "on" } else { "off" };
        return format!("uci set dropbear.@dropbear[0].PasswordAuth='{v}' && uci set dropbear.@dropbear[0].RootPasswordAuth='{v}' && uci commit dropbear && /etc/init.d/dropbear restart");
    }
    let sudo = if os == ServerOs::Alpine { "" } else { "sudo " };
    let reload = match os {
        ServerOs::Alpine => "rc-service sshd restart",
        ServerOs::Macos => "sudo launchctl kickstart -k system/com.openssh.sshd",
        ServerOs::Freebsd => "sudo service sshd restart",
        _ => "(sudo systemctl reload ssh || sudo systemctl reload sshd)",
    };
    let v = if enabled { "yes" } else { "no" };
    let script = password_script(enabled, "/etc/ssh/sshd_config", "/etc/ssh/sshd_config.d") + "; sshd -t";
    // После перезапуска — проверка действующего значения: другой Include или Match могли его перебить.
    let verify = format!("sshd -T 2>/dev/null | grep -qix 'passwordauthentication {v}' || {{ echo RELAYA_SSHD_MISMATCH >&2; exit 1; }}");
    format!("{sudo}sh -c {} && {reload} && {sudo}sh -c {}", crate::shell_quote(&script), crate::shell_quote(&verify))
}

/// Правка sshd_config (от root): без строки директивы она дописывается в начало файла.
fn password_script(enabled: bool, file: &str, dropin_dir: &str) -> String {
    let v = if enabled { "yes" } else { "no" };
    // Выключая пароль, выключаем и keyboard-interactive: иначе PAM продолжит спрашивать пароль.
    let keys: &[&str] = if enabled { &["PasswordAuthentication"] } else { &["PasswordAuthentication", "KbdInteractiveAuthentication"] };
    let dropin: String = keys.iter().map(|k| format!("{k} {v}\\n")).collect();
    let edits: String = keys.iter().map(|k| format!(
        "if grep -qsE '^#?[[:space:]]*{k}[[:space:]]' \"$f\"; then sed -i.relaya -E 's/^#?[[:space:]]*{k}[[:space:]].*/{k} {v}/' \"$f\" && rm -f \"$f.relaya\"; \
         else {{ echo '{k} {v}'; cat \"$f\"; }} > \"$f.relaya\" && cat \"$f.relaya\" > \"$f\" && rm -f \"$f.relaya\"; fi; ")).collect();
    // Своё правило — раньше всех в sshd_config.d (у sshd побеждает первое значение), строка без директивы дописывается
    // в начало файла (в конце она попала бы в блок Match).
    format!("set -e; f={file}; d={dropin_dir}; \
        if grep -qsE \"^Include $d\" \"$f\"; then rm -f \"$d/00-relaya.conf\"; \
        printf '{dropin}' > \"$d/00-00-relaya.conf\"; else cp \"$f\" \"$f.bak\"; {edits}fi")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_and_banner() {
        assert_eq!(os_parse_probe("Linux\nNAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n".into()), Some(ServerOs::Ubuntu));
        assert_eq!(os_parse_probe("Linux\nID=kali\nID_LIKE=debian\n".into()), Some(ServerOs::Kali));
        assert_eq!(os_parse_probe("Linux\nID=debian\nID=proxmox\n".into()), Some(ServerOs::Proxmox));
        assert_eq!(os_parse_probe("Linux\nID=someforkofdebian\nID_LIKE=debian\n".into()), Some(ServerOs::Debian));
        assert_eq!(os_parse_probe("Darwin\n".into()), Some(ServerOs::Macos));
        assert_eq!(os_guess_from_banner("Welcome to Ubuntu 24.04 LTS".into()), Some(ServerOs::Ubuntu));
    }

    #[test]
    fn raw_roundtrip_and_commands() {
        for os in os_all() { assert_eq!(ServerOs::from_raw(os.raw()), Some(os)); }
        let off = os_password_login_command(ServerOs::Ubuntu, false);
        assert!(off.contains("PasswordAuthentication no") && off.contains("KbdInteractiveAuthentication no"), "{off}");
        assert!(off.contains("sshd -T") && off.contains("RELAYA_SSHD_MISMATCH"));
        let on = os_password_login_command(ServerOs::Ubuntu, true);
        assert!(on.contains("PasswordAuthentication yes") && !on.contains("KbdInteractive"));
        assert!(os_password_login_command(ServerOs::Openwrt, false).contains("PasswordAuth='off'"));
        // Скрипт реально работает: файл без строки PasswordAuthentication и с блоком Match, и вариант с Include.
        if cfg!(unix) {
            let dir = tempfile::tempdir().unwrap();
            let (f, d) = (dir.path().join("sshd_config"), dir.path().join("conf.d"));
            let run = |sc: String| assert!(std::process::Command::new("sh").arg("-c").arg(&sc).status().unwrap().success(), "{sc}");
            std::fs::write(&f, "Port 22\nMatch User x\n  X11Forwarding no\n").unwrap();
            run(password_script(false, &f.to_string_lossy(), &d.to_string_lossy()));
            let out = std::fs::read_to_string(&f).unwrap();
            assert!(out.starts_with("KbdInteractiveAuthentication no\nPasswordAuthentication no\nPort 22"), "{out}");
            run(password_script(true, &f.to_string_lossy(), &d.to_string_lossy()));
            assert!(std::fs::read_to_string(&f).unwrap().starts_with("KbdInteractiveAuthentication no\nPasswordAuthentication yes\n"));
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(&f, format!("Include {}/*.conf\n", d.to_string_lossy())).unwrap();
            run(password_script(false, &f.to_string_lossy(), &d.to_string_lossy()));
            assert_eq!(std::fs::read_to_string(d.join("00-00-relaya.conf")).unwrap(), "PasswordAuthentication no\nKbdInteractiveAuthentication no\n");
        }
        assert_eq!(os_actions(ServerOs::Debian)[0].command, "sudo apt update && sudo apt upgrade");
    }
}
