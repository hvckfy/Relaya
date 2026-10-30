import Foundation

/// Операционная система сервера. Хранится в `# relaya: os=…`.
public enum ServerOS: String, Sendable, CaseIterable {
    case ubuntu, debian, raspbian, fedora, centos, rhel, rocky, alma, alpine, arch, opensuse
    case openwrt, linux, macos, freebsd, windows
    case mint, popos, elementary, zorin, kali, proxmox, manjaro, endeavouros, gentoo, nixos, void, openbsd

    public var title: String {
        switch self {
        case .ubuntu: "Ubuntu"
        case .debian: "Debian"
        case .raspbian: "Raspberry Pi OS"
        case .fedora: "Fedora"
        case .centos: "CentOS"
        case .rhel: "Red Hat"
        case .rocky: "Rocky Linux"
        case .alma: "AlmaLinux"
        case .alpine: "Alpine"
        case .arch: "Arch Linux"
        case .opensuse: "openSUSE"
        case .openwrt: "OpenWrt"
        case .linux: "Linux"
        case .macos: "macOS"
        case .freebsd: "FreeBSD"
        case .windows: "Windows"
        case .mint: "Linux Mint"
        case .popos: "Pop!_OS"
        case .elementary: "elementary OS"
        case .zorin: "Zorin OS"
        case .kali: "Kali Linux"
        case .proxmox: "Proxmox VE"
        case .manjaro: "Manjaro"
        case .endeavouros: "EndeavourOS"
        case .gentoo: "Gentoo"
        case .nixos: "NixOS"
        case .void: "Void Linux"
        case .openbsd: "OpenBSD"
        }
    }

    public enum PackageManager: Sendable { case apt, dnf, yum, apk, pacman, zypper, opkg, brew, pkg }

    public var packageManager: PackageManager? {
        switch self {
        case .ubuntu, .debian, .raspbian, .mint, .popos, .elementary, .zorin, .kali, .proxmox: .apt
        case .manjaro, .endeavouros: .pacman
        case .fedora, .rocky, .alma, .rhel: .dnf
        case .centos: .yum
        case .alpine: .apk
        case .arch: .pacman
        case .opensuse: .zypper
        case .openwrt: .opkg
        case .macos: .brew
        case .freebsd: .pkg
        case .linux, .windows, .gentoo, .nixos, .void, .openbsd: nil
        }
    }

    /// Команда, которую запускает фоновая проверка. POSIX sh; на Windows вернёт ошибку — это тоже ответ.
    public static let probeCommand =
        "uname -s 2>/dev/null; cat /etc/os-release 2>/dev/null; [ -f /etc/openwrt_release ] && echo ID=openwrt; [ -d /etc/pve ] && echo ID=proxmox; true"

    /// Разбор вывода `probeCommand`.
    public static func parse(probe: String) -> ServerOS? {
        var id: String?
        var idLike: [String] = []
        var uname: String?
        for raw in probe.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ID=") {
                // ID=openwrt из openwrt_release печатается последним и важнее os-release.
                id = unquote(String(line.dropFirst(3))).lowercased()
            } else if line.hasPrefix("ID_LIKE=") {
                idLike = unquote(String(line.dropFirst(8))).lowercased().split(separator: " ").map(String.init)
            } else if uname == nil, !line.contains("=") {
                uname = line.lowercased()
            }
        }
        if let id, let os = fromID(id) { return os }
        for like in idLike { if let os = fromID(like) { return os } }
        switch uname {
        case "darwin": return .macos
        case "freebsd": return .freebsd
        case "openbsd": return .openbsd
        case "linux": return .linux
        case let u? where u.contains("mingw") || u.contains("cygwin") || u.contains("msys"): return .windows
        default: break
        }
        if probe.contains("is not recognized as an internal or external command") { return .windows }
        return nil
    }

    static func fromID(_ id: String) -> ServerOS? {
        switch id {
        case "ubuntu": .ubuntu
        case "linuxmint": .mint
        case "pop": .popos
        case "elementary": .elementary
        case "zorin": .zorin
        case "kali": .kali
        case "proxmox": .proxmox
        case "manjaro", "manjaro-arm": .manjaro
        case "endeavouros": .endeavouros
        case "gentoo": .gentoo
        case "nixos": .nixos
        case "void": .void
        case "debian": .debian
        case "raspbian": .raspbian
        case "fedora": .fedora
        case "centos": .centos
        case "rhel": .rhel
        case "rocky": .rocky
        case "almalinux": .alma
        case "alpine": .alpine
        case "arch": .arch
        case "opensuse", "opensuse-leap", "opensuse-tumbleweed", "sles", "suse": .opensuse
        case "openwrt": .openwrt
        default: nil
        }
    }

    /// Догадка по приветствию сервера в терминале (если фоновая проверка невозможна).
    public static func guess(fromBanner text: String) -> ServerOS? {
        let checks: [(String, ServerOS)] = [
            ("OpenWrt", .openwrt), ("Raspbian", .raspbian), ("Linux Mint", .mint), ("Pop!_OS", .popos),
            ("Kali", .kali), ("pve-manager", .proxmox), ("Manjaro", .manjaro), ("Ubuntu", .ubuntu), ("Debian GNU/Linux", .debian),
            ("Alpine", .alpine), ("Fedora", .fedora), ("CentOS", .centos), ("Rocky Linux", .rocky),
            ("AlmaLinux", .alma), ("Red Hat Enterprise", .rhel), ("Arch Linux", .arch), ("openSUSE", .opensuse),
            ("FreeBSD", .freebsd), ("Microsoft Windows", .windows),
        ]
        return checks.first { text.contains($0.0) }?.1
    }

    private static func unquote(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}

/// Готовые команды для меню «Действия» в сессии.
public struct OSAction: Sendable, Hashable {
    public var title: String
    public var command: String
    public var needsRoot: Bool

    public init(_ title: String, _ command: String, needsRoot: Bool = false) {
        self.title = title
        self.command = command
        self.needsRoot = needsRoot
    }
}

extension ServerOS {
    public var actions: [OSAction] {
        var list: [OSAction] = []
        switch packageManager {
        case .apt?:
            list += [OSAction(L("Обновить пакеты"), "sudo apt update && sudo apt upgrade", needsRoot: true),
                     OSAction(L("Установить пакет…"), "sudo apt install ", needsRoot: true),
                     OSAction(L("Удалить ненужные пакеты"), "sudo apt autoremove", needsRoot: true)]
        case .dnf?:
            list += [OSAction(L("Обновить пакеты"), "sudo dnf upgrade", needsRoot: true),
                     OSAction(L("Установить пакет…"), "sudo dnf install ", needsRoot: true)]
        case .yum?:
            list += [OSAction(L("Обновить пакеты"), "sudo yum update", needsRoot: true),
                     OSAction(L("Установить пакет…"), "sudo yum install ", needsRoot: true)]
        case .apk?:
            list += [OSAction(L("Обновить пакеты"), "apk update && apk upgrade", needsRoot: true),
                     OSAction(L("Установить пакет…"), "apk add ", needsRoot: true)]
        case .pacman?:
            list += [OSAction(L("Обновить пакеты"), "sudo pacman -Syu", needsRoot: true),
                     OSAction(L("Установить пакет…"), "sudo pacman -S ", needsRoot: true)]
        case .zypper?:
            list += [OSAction(L("Обновить пакеты"), "sudo zypper refresh && sudo zypper update", needsRoot: true),
                     OSAction(L("Установить пакет…"), "sudo zypper install ", needsRoot: true)]
        case .opkg?:
            list += [OSAction(L("Обновить список пакетов"), "opkg update"),
                     OSAction(L("Обновляемые пакеты"), "opkg list-upgradable"),
                     OSAction(L("Установить пакет…"), "opkg install ")]
        case .brew?:
            list += [OSAction(L("Обновить пакеты"), "brew update && brew upgrade"),
                     OSAction(L("Установить пакет…"), "brew install ")]
        case .pkg?:
            list += [OSAction(L("Обновить пакеты"), "sudo pkg update && sudo pkg upgrade", needsRoot: true),
                     OSAction(L("Установить пакет…"), "sudo pkg install ", needsRoot: true)]
        case nil:
            break
        }

        switch self {
        case .openwrt:
            list += [OSAction(L("Сведения о системе"), "ubus call system board"),
                     OSAction(L("Сетевые интерфейсы"), "ifstatus wan; ip -br addr"),
                     OSAction(L("Wi-Fi клиенты"), "iwinfo; for i in $(iwinfo | awk '/ESSID/{print $1}'); do iwinfo $i assoclist; done"),
                     OSAction(L("Журнал"), "logread | tail -n 100"),
                     OSAction(L("Перезапустить сеть"), "/etc/init.d/network restart")]
        case .macos:
            list += [OSAction(L("Сведения о системе"), "sw_vers; uname -m; uptime"),
                     OSAction(L("Место на диске"), "df -h /"),
                     OSAction(L("Нагрузка"), "top -l 1 -n 10 -o cpu")]
        case .freebsd:
            list += [OSAction(L("Сведения о системе"), "freebsd-version; uname -a; uptime"),
                     OSAction(L("Место на диске"), "df -h"),
                     OSAction(L("Сервисы"), "service -e")]
        case .windows:
            list += [OSAction(L("Сведения о системе"), "systeminfo"),
                     OSAction(L("Место на диске"), "wmic logicaldisk get caption,freespace,size"),
                     OSAction(L("Процессы"), "tasklist")]
        default:
            list += [OSAction(L("Сведения о системе"), "cat /etc/os-release; uname -a; uptime"),
                     OSAction(L("Место на диске"), "df -h"),
                     OSAction(L("Память"), "free -h"),
                     OSAction(L("Нагрузка"), "top -b -n 1 | head -n 20"),
                     OSAction(L("Упавшие сервисы"), "systemctl --failed"),
                     OSAction(L("Журнал (последние ошибки)"), "sudo journalctl -p err -n 50 --no-pager", needsRoot: true)]
        }
        return list
    }

    /// Команда, включающая или отключающая вход по паролю на сервере.
    /// Relaya её не выполняет: только показывает или вставляет в терминал без Enter.
    public func passwordLoginCommand(enabled: Bool) -> String {
        if self == .openwrt {
            let v = enabled ? "on" : "off"
            return "uci set dropbear.@dropbear[0].PasswordAuth='\(v)' && uci set dropbear.@dropbear[0].RootPasswordAuth='\(v)' && uci commit dropbear && /etc/init.d/dropbear restart"
        }
        let sudo = self == .alpine ? "" : "sudo "
        let reload: String
        switch self {
        case .alpine: reload = "rc-service sshd restart"
        case .macos: reload = "sudo launchctl kickstart -k system/com.openssh.sshd"
        case .freebsd: reload = "sudo service sshd restart"
        default: reload = "(sudo systemctl reload ssh || sudo systemctl reload sshd)"
        }
        let v = enabled ? "yes" : "no"
        // Где есть sshd_config.d, пишем свой файл с префиксом 00: в sshd побеждает первое значение,
        // так он перекрывает, например, 50-cloud-init.conf в Ubuntu. Иначе правим основной конфиг.
        return "if grep -qsE '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config; then "
            + "echo 'PasswordAuthentication \(v)' | \(sudo)tee /etc/ssh/sshd_config.d/00-relaya.conf >/dev/null; else "
            + #"\#(sudo)sed -i.bak -E 's/^#?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication \#(v)/' /etc/ssh/sshd_config; fi"#
            + " && \(sudo)sshd -t && \(reload)"
    }

    /// Пункты меню «Вход по паролю».
    public var passwordLoginActions: [OSAction] {
        guard self != .windows else { return [] }
        return [OSAction(L("Разрешить вход по паролю"), passwordLoginCommand(enabled: true), needsRoot: true),
                OSAction(L("Запретить вход по паролю"), passwordLoginCommand(enabled: false), needsRoot: true)]
    }
}
