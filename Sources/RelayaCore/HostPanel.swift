import Foundation
import RelayaRust

/// systemd-сервис на хосте.
public struct ServiceUnit: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var active: String
    public var sub: String
    public var description: String

    public var isFailed: Bool { active == "failed" }
    public var isRunning: Bool { active == "active" && sub == "running" }
    /// Активен (работает или выполнился и висит как active/exited) или в процессе запуска/остановки.
    public var isActive: Bool { active == "active" || active == "activating" || active == "reloading" || active == "deactivating" }
    /// Порядок в списке: упавшие → работающие → прочие активные → остановленные.
    public var rank: Int { isFailed ? 0 : isRunning ? 1 : isActive ? 2 : 3 }
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

    // Логика — в Rust-ядре (`core/src/host_panel.rs`).
    public static func probeCommand(for os: ServerOS?) -> String { hostPanelProbeCommand(os: os?.rust) }

    public static func parse(_ output: String) -> HostPanel {
        let p = hostPanelParse(output: output)
        return HostPanel(
            services: p.services.map { ServiceUnit(name: $0.name, active: $0.active, sub: $0.sub, description: $0.description) },
            ports: p.ports.map { ListeningPort(proto: $0.proto, address: $0.address, process: $0.process) },
            errors: p.errors, updates: p.updates, hasSystemd: p.hasSystemd)
    }

    /// systemctl-действие над сервисом; `sudo` — если вошли не под root.
    public static func serviceCommand(_ action: String, _ unit: ServiceUnit, root: Bool) -> String {
        precondition(["start", "stop", "restart"].contains(action))
        return RelayaRust.serviceCommand(action: action, unit: unit.name, root: root)
    }

    public static func serviceLogsCommand(_ unit: ServiceUnit, root: Bool) -> String {
        RelayaRust.serviceLogsCommand(unit: unit.name, root: root)
    }
}
