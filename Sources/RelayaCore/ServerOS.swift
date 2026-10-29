import Foundation

/// Операционная система сервера. Хранится в `# relaya: os=…`.
public enum ServerOS: String, Sendable, CaseIterable {
    case ubuntu, debian, raspbian, fedora, centos, rhel, rocky, alma, alpine, arch, opensuse
    case openwrt, linux, macos, freebsd, windows

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
        }
    }

    public enum PackageManager: Sendable { case apt, dnf, yum, apk, pacman, zypper, opkg, brew, pkg }

    public var packageManager: PackageManager? {
        switch self {
        case .ubuntu, .debian, .raspbian: .apt
        case .fedora, .rocky, .alma, .rhel: .dnf
        case .centos: .yum
        case .alpine: .apk
        case .arch: .pacman
        case .opensuse: .zypper
        case .openwrt: .opkg
        case .macos: .brew
        case .freebsd: .pkg
        case .linux, .windows: nil
        }
    }

    /// Команда, которую запускает фоновая проверка. POSIX sh; на Windows вернёт ошибку — это тоже ответ.
    public static let probeCommand =
        "uname -s 2>/dev/null; cat /etc/os-release 2>/dev/null; [ -f /etc/openwrt_release ] && echo ID=openwrt; true"

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
        case "linux": return .linux
        case let u? where u.contains("mingw") || u.contains("cygwin") || u.contains("msys"): return .windows
        default: break
        }
        if probe.contains("is not recognized as an internal or external command") { return .windows }
        return nil
    }

    static func fromID(_ id: String) -> ServerOS? {
        switch id {
        case "ubuntu", "pop", "linuxmint", "elementary": .ubuntu
        case "debian": .debian
        case "raspbian": .raspbian
        case "fedora": .fedora
        case "centos": .centos
        case "rhel": .rhel
        case "rocky": .rocky
        case "almalinux": .alma
        case "alpine": .alpine
        case "arch", "manjaro", "endeavouros": .arch
        case "opensuse", "opensuse-leap", "opensuse-tumbleweed", "sles", "suse": .opensuse
        case "openwrt": .openwrt
        default: nil
        }
    }

    /// Догадка по приветствию сервера в терминале (если фоновая проверка невозможна).
    public static func guess(fromBanner text: String) -> ServerOS? {
        let checks: [(String, ServerOS)] = [
            ("OpenWrt", .openwrt), ("Raspbian", .raspbian), ("Ubuntu", .ubuntu), ("Debian GNU/Linux", .debian),
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
            list += [OSAction("Обновить пакеты", "sudo apt update && sudo apt upgrade", needsRoot: true),
                     OSAction("Установить пакет…", "sudo apt install ", needsRoot: true),
                     OSAction("Удалить ненужные пакеты", "sudo apt autoremove", needsRoot: true)]
        case .dnf?:
            list += [OSAction("Обновить пакеты", "sudo dnf upgrade", needsRoot: true),
                     OSAction("Установить пакет…", "sudo dnf install ", needsRoot: true)]
        case .yum?:
            list += [OSAction("Обновить пакеты", "sudo yum update", needsRoot: true),
                     OSAction("Установить пакет…", "sudo yum install ", needsRoot: true)]
        case .apk?:
            list += [OSAction("Обновить пакеты", "apk update && apk upgrade", needsRoot: true),
                     OSAction("Установить пакет…", "apk add ", needsRoot: true)]
        case .pacman?:
            list += [OSAction("Обновить пакеты", "sudo pacman -Syu", needsRoot: true),
                     OSAction("Установить пакет…", "sudo pacman -S ", needsRoot: true)]
        case .zypper?:
            list += [OSAction("Обновить пакеты", "sudo zypper refresh && sudo zypper update", needsRoot: true),
                     OSAction("Установить пакет…", "sudo zypper install ", needsRoot: true)]
        case .opkg?:
            list += [OSAction("Обновить список пакетов", "opkg update"),
                     OSAction("Обновляемые пакеты", "opkg list-upgradable"),
                     OSAction("Установить пакет…", "opkg install ")]
        case .brew?:
            list += [OSAction("Обновить пакеты", "brew update && brew upgrade"),
                     OSAction("Установить пакет…", "brew install ")]
        case .pkg?:
            list += [OSAction("Обновить пакеты", "sudo pkg update && sudo pkg upgrade", needsRoot: true),
                     OSAction("Установить пакет…", "sudo pkg install ", needsRoot: true)]
        case nil:
            break
        }

        switch self {
        case .openwrt:
            list += [OSAction("Сведения о системе", "ubus call system board"),
                     OSAction("Сетевые интерфейсы", "ifstatus wan; ip -br addr"),
                     OSAction("Wi-Fi клиенты", "iwinfo; for i in $(iwinfo | awk '/ESSID/{print $1}'); do iwinfo $i assoclist; done"),
                     OSAction("Журнал", "logread | tail -n 100"),
                     OSAction("Перезапустить сеть", "/etc/init.d/network restart")]
        case .macos:
            list += [OSAction("Сведения о системе", "sw_vers; uname -m; uptime"),
                     OSAction("Место на диске", "df -h /"),
                     OSAction("Нагрузка", "top -l 1 -n 10 -o cpu")]
        case .freebsd:
            list += [OSAction("Сведения о системе", "freebsd-version; uname -a; uptime"),
                     OSAction("Место на диске", "df -h"),
                     OSAction("Сервисы", "service -e")]
        case .windows:
            list += [OSAction("Сведения о системе", "systeminfo"),
                     OSAction("Место на диске", "wmic logicaldisk get caption,freespace,size"),
                     OSAction("Процессы", "tasklist")]
        default:
            list += [OSAction("Сведения о системе", "cat /etc/os-release; uname -a; uptime"),
                     OSAction("Место на диске", "df -h"),
                     OSAction("Память", "free -h"),
                     OSAction("Нагрузка", "top -b -n 1 | head -n 20"),
                     OSAction("Упавшие сервисы", "systemctl --failed"),
                     OSAction("Журнал (последние ошибки)", "sudo journalctl -p err -n 50 --no-pager", needsRoot: true)]
        }
        return list
    }

    /// Как отключить вход по паролю (показываем, сами не выполняем).
    public var disablePasswordCommand: String {
        switch self {
        case .openwrt:
            "uci set dropbear.@dropbear[0].PasswordAuth='off' && uci set dropbear.@dropbear[0].RootPasswordAuth='off' && uci commit dropbear && /etc/init.d/dropbear restart"
        case .alpine:
            #"sed -i.bak -E 's/^#?\s*PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sshd -t && rc-service sshd restart"#
        case .macos:
            #"sudo sed -i.bak -E 's/^#?\s*PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sudo launchctl kickstart -k system/com.openssh.sshd"#
        case .freebsd:
            #"sudo sed -i.bak -E 's/^#?\s*PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sudo sshd -t && sudo service sshd restart"#
        default:
            KeyInstaller.disablePasswordCommand
        }
    }
}
