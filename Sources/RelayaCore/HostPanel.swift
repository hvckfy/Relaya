import Foundation

/// systemd-сервис на хосте.
public struct ServiceUnit: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var active: String
    public var sub: String
    public var description: String

    public var isFailed: Bool { active == "failed" }
    public var isRunning: Bool { active == "active" && sub == "running" }
    /// Имя без `.service` — для подписи.
    public var shortName: String { name.hasSuffix(".service") ? String(name.dropLast(8)) : name }
}

/// Слушающий порт.
public struct ListeningPort: Identifiable, Hashable, Sendable {
    public var id: String { "\(proto) \(address)" }
    public var proto: String
    public var address: String
    public var process: String?

    /// Номер порта — для сортировки и ссылок.
    public var port: Int? { address.split(separator: ":").last.flatMap { Int($0) } }
}

/// Лёгкая мини-панель хоста: сервисы, порты, ошибки журнала, обновления — одной командой по ssh, без агента.
public struct HostPanel: Equatable, Sendable {
    public var services: [ServiceUnit]
    public var ports: [ListeningPort]
    public var errors: [String]
    /// nil — менеджер пакетов не поддерживается.
    public var updates: [String]?
    public var hasSystemd: Bool

    public static func probeCommand(for os: ServerOS?) -> String {
        """
        echo '##SERVICES'; systemctl list-units --type=service --all --no-legend --plain --no-pager 2>/dev/null | head -n 400
        echo '##PORTS'; ss -tulnpH 2>/dev/null | head -n 200
        echo '##ERRORS'; journalctl -p err -n 20 --no-pager -o short-iso 2>/dev/null
        echo '##UPDATES'; \(updatesCommand(for: os) ?? "echo RELAYA_NO_PM")
        true
        """
    }

    /// Список доступных обновлений без обращения к сети, где это возможно.
    static func updatesCommand(for os: ServerOS?) -> String? {
        switch os?.packageManager {
        case .apt?: "apt list --upgradable 2>/dev/null | grep -v '^Listing' | head -n 300"
        case .dnf?: "dnf -q --cacheonly check-update 2>/dev/null | awk 'NF==3{print $1}' | head -n 300"
        case .yum?: "yum -q -C check-update 2>/dev/null | awk 'NF==3{print $1}' | head -n 300"
        case .apk?: "apk -u list 2>/dev/null | head -n 300"
        case .pacman?: "pacman -Qu 2>/dev/null | head -n 300"
        case .zypper?: "zypper -q --no-refresh lu 2>/dev/null | awk -F'|' 'NR>2{gsub(/ /,\"\",$3); print $3}' | head -n 300"
        case .opkg?: "opkg list-upgradable 2>/dev/null | head -n 300"
        default: nil
        }
    }

    public static func parse(_ output: String) -> HostPanel {
        var section = ""
        var services: [ServiceUnit] = []
        var ports: [ListeningPort] = []
        var errors: [String] = []
        var updates: [String]? = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("##") { section = line; continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            switch section {
            case "##SERVICES":
                let f = t.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
                guard f.count >= 4, f[0].hasSuffix(".service") else { continue }
                services.append(ServiceUnit(name: f[0], active: f[2], sub: f[3], description: f.count > 4 ? f[4] : ""))
            case "##PORTS":
                let f = t.split(whereSeparator: \.isWhitespace).map(String.init)
                guard f.count >= 5 else { continue }
                var process: String?
                if let users = f.first(where: { $0.hasPrefix("users:") }),
                   let a = users.range(of: "((\""), let b = users[a.upperBound...].range(of: "\"") {
                    process = String(users[a.upperBound..<b.lowerBound])
                }
                ports.append(ListeningPort(proto: f[0], address: f[4], process: process))
            case "##ERRORS":
                if !t.hasPrefix("-- ") { errors.append(t) }
            case "##UPDATES":
                if t == "RELAYA_NO_PM" { updates = nil; continue }
                let name = t.split(whereSeparator: { $0 == "/" || $0 == " " }).first.map(String.init) ?? t
                updates?.append(name)
            default:
                break
            }
        }
        // Уникальные порты: tcp/udp × адрес; сначала меньшие номера.
        var seen = Set<String>()
        ports = ports.filter { seen.insert($0.id).inserted }.sorted { ($0.port ?? 0, $0.proto) < ($1.port ?? 0, $1.proto) }
        services.sort { ($0.isFailed ? 0 : 1, $0.name) < ($1.isFailed ? 0 : 1, $1.name) }
        return HostPanel(services: services, ports: ports, errors: errors, updates: updates,
                         hasSystemd: !services.isEmpty)
    }

    /// systemctl-действие над сервисом; `sudo` — если вошли не под root.
    public static func serviceCommand(_ action: String, _ unit: ServiceUnit, root: Bool) -> String {
        precondition(["start", "stop", "restart"].contains(action))
        return (root ? "" : "sudo ") + "systemctl \(action) " + quote(unit.name)
    }

    public static func serviceLogsCommand(_ unit: ServiceUnit, root: Bool) -> String {
        (root ? "" : "sudo ") + "journalctl -u " + quote(unit.name) + " -n 200 -f"
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
