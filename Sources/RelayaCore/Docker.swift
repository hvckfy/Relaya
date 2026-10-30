import Foundation

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

    public static let listCommand = #"command -v docker >/dev/null 2>&1 || { echo RELAYA_NO_DOCKER; exit 0; }; docker ps -a --format '{{json .}}'"#

    public static func parse(stdout: String, stderr: String, status: Int32) -> ListResult {
        if stdout.contains("RELAYA_NO_DOCKER") { return .notInstalled }
        if stderr.contains("permission denied") || stderr.contains("Got permission denied") { return .permissionDenied }
        var list: [DockerContainer] = []
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            func str(_ k: String) -> String { obj[k] as? String ?? "" }
            list.append(DockerContainer(id: str("ID"), name: str("Names"), image: str("Image"),
                                        state: str("State").lowercased(), status: str("Status"), ports: str("Ports")))
        }
        if list.isEmpty, status != 0 {
            let message = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(status)"
            return .failed(message)
        }
        return .containers(list.sorted {
            $0.isRunning != $1.isRunning ? $0.isRunning : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    /// Имя контейнера для командной строки (POSIX sh).
    public static func quoted(_ name: String) -> String {
        "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func actionCommand(_ action: String, container: DockerContainer) -> String {
        "docker \(action) \(quoted(container.name))"
    }

    public static func logsCommand(_ container: DockerContainer) -> String {
        "docker logs -f --tail 200 \(quoted(container.name))"
    }

    /// Оболочка внутри контейнера: bash, если есть, иначе sh.
    public static func shellCommand(_ container: DockerContainer) -> String {
        "docker exec -it \(quoted(container.name)) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
    }
}
