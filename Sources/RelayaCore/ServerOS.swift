import Foundation
import RelayaRust

/// Операционная система сервера. Хранится в `# relaya: os=…`.
public enum ServerOS: String, Sendable, CaseIterable {
    case ubuntu, debian, raspbian, fedora, centos, rhel, rocky, alma, alpine, arch, opensuse
    case openwrt, linux, macos, freebsd, windows
    case mint, popos, elementary, zorin, kali, proxmox, manjaro, endeavouros, gentoo, nixos, void, openbsd

    // Логика — в Rust-ядре (`core/src/server_os.rs`); здесь — Swift-фасад с тем же API.

    /// Значение того же случая в Rust-ядре.
    var rust: RelayaRust.ServerOs { osFromRaw(raw: rawValue)! }

    init?(rust: RelayaRust.ServerOs) { self.init(rawValue: osRaw(os: rust)) }

    public var title: String { osTitle(os: rust) }

    public enum PackageManager: Sendable { case apt, dnf, yum, apk, pacman, zypper, opkg, brew, pkg }

    public var packageManager: PackageManager? {
        switch osPackageManager(os: rust) {
        case .apt?: .apt
        case .dnf?: .dnf
        case .yum?: .yum
        case .apk?: .apk
        case .pacman?: .pacman
        case .zypper?: .zypper
        case .opkg?: .opkg
        case .brew?: .brew
        case .pkg?: .pkg
        case nil: nil
        }
    }

    /// Команда фоновой проверки. POSIX sh; на Windows вернёт ошибку — это тоже ответ.
    public static var probeCommand: String { osProbeCommand() }

    /// Разбор вывода `probeCommand`.
    public static func parse(probe: String) -> ServerOS? { osParseProbe(probe: probe).flatMap(ServerOS.init(rust:)) }

    /// Догадка по приветствию сервера в терминале.
    public static func guess(fromBanner text: String) -> ServerOS? { osGuessFromBanner(text: text).flatMap(ServerOS.init(rust:)) }
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
    /// Подписи из ядра — ключи локализации, переводятся здесь.
    public var actions: [OSAction] {
        osActions(os: rust).map { OSAction(L($0.title), $0.command, needsRoot: $0.needsRoot) }
    }

    /// Команда, включающая или отключающая вход по паролю на сервере.
    public func passwordLoginCommand(enabled: Bool) -> String { osPasswordLoginCommand(os: rust, enabled: enabled) }

    /// Пункты меню «Вход по паролю».
    public var passwordLoginActions: [OSAction] {
        guard self != .windows else { return [] }
        return [OSAction(L("Разрешить вход по паролю"), passwordLoginCommand(enabled: true), needsRoot: true),
                OSAction(L("Запретить вход по паролю"), passwordLoginCommand(enabled: false), needsRoot: true)]
    }
}
