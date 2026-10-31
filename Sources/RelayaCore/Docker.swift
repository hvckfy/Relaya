import Foundation
import RelayaRust

/// Контейнер Docker на сервере (из `docker ps -a --format '{{json .}}'`).
public struct DockerContainer: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    /// running, exited, paused, restarting, created, dead.
    public var state: String
    /// «Up 2 hours», «Exited (0) 3 days ago».
    public var status: String
    public var ports: String

    public var isRunning: Bool { state == "running" || state == "restarting" }

    public init(id: String, name: String, image: String, state: String, status: String, ports: String) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
    }
}

public enum Docker {
    /// Что вернула команда списка.
    public enum ListResult: Equatable, Sendable {
        case containers([DockerContainer])
        /// Docker не установлен — блок не показываем.
        case notInstalled
        /// Нет прав на сокет Docker.
        case permissionDenied
        case failed(String)
    }

    // Логика — в Rust-ядре (`core/src/docker.rs`).
    public static var listCommand: String { dockerListCommand() }

    public static func parse(stdout: String, stderr: String, status: Int32) -> ListResult {
        switch dockerParse(stdout: stdout, stderr: stderr, status: status) {
        case .containers(let list):
            return .containers(list.map { DockerContainer(id: $0.id, name: $0.name, image: $0.image, state: $0.state,
                                                          status: $0.status, ports: $0.ports) })
        case .notInstalled: return .notInstalled
        case .permissionDenied: return .permissionDenied
        case .failed(let m): return .failed(m)
        }
    }

    /// Имя контейнера для командной строки (POSIX sh).
    public static func quoted(_ name: String) -> String { coreShellQuote(s: name) }

    public static func actionCommand(_ action: String, container: DockerContainer) -> String {
        dockerActionCommand(action: action, name: container.name)
    }

    public static func logsCommand(_ container: DockerContainer) -> String { dockerLogsCommand(name: container.name) }

    /// Оболочка внутри контейнера: bash, если есть, иначе sh.
    public static func shellCommand(_ container: DockerContainer) -> String { dockerShellCommand(name: container.name) }
}
