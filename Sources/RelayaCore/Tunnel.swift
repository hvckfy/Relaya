import Foundation

/// Проброс порта через ssh. Запускается отдельным процессом `ssh -N`.
public struct Tunnel: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// `-L`: локальный порт → адрес, видимый с сервера.
        case local
        /// `-R`: порт на сервере → адрес, видимый с этого Mac.
        case remote
        /// `-D`: SOCKS-прокси на локальном порту.
        case dynamic

        public var flag: String {
            switch self {
            case .local: "-L"
            case .remote: "-R"
            case .dynamic: "-D"
            }
        }

        public var title: String {
            switch self {
            case .local: "Локальный (-L)"
            case .remote: "Удалённый (-R)"
            case .dynamic: "SOCKS (-D)"
            }
        }
    }

    public var id = UUID()
    public var name: String
    public var hostAlias: String
    public var kind: Kind
    /// Порт, который слушается: на этом Mac для -L/-D, на сервере для -R.
    public var listenPort: Int
    /// Куда пробрасывать (не нужно для -D).
    public var targetHost: String
    public var targetPort: Int
    /// Поднимать при запуске Relaya.
    public var autoStart: Bool

    public init(name: String, hostAlias: String, kind: Kind = .local, listenPort: Int,
                targetHost: String = "localhost", targetPort: Int = 0, autoStart: Bool = false) {
        self.name = name
        self.hostAlias = hostAlias
        self.kind = kind
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.autoStart = autoStart
    }

    /// Спецификация проброса для ssh: `8080:localhost:80` или `1080`.
    public var spec: String {
        kind == .dynamic ? "\(listenPort)" : "\(listenPort):\(targetHost):\(targetPort)"
    }

    /// Короткое описание: `localhost:8080 → db:5432 через web`.
    public var summary: String {
        switch kind {
        case .local: "localhost:\(listenPort) → \(targetHost):\(targetPort) через \(hostAlias)"
        case .remote: "\(hostAlias):\(listenPort) → \(targetHost):\(targetPort) на этом Mac"
        case .dynamic: "SOCKS localhost:\(listenPort) через \(hostAlias)"
        }
    }

    public var validationError: String? {
        if hostAlias.isEmpty { return "Выберите хост" }
        if !(1...65535).contains(listenPort) { return "Порт — число от 1 до 65535" }
        if kind != .dynamic {
            if targetHost.trimmingCharacters(in: .whitespaces).isEmpty { return "Укажите адрес назначения" }
            if !(1...65535).contains(targetPort) { return "Порт назначения — число от 1 до 65535" }
        }
        return nil
    }

    /// Аргументы `ssh` без секретов. Пароль, если нужен, — через askpass.
    public func sshArguments(passwordOnly: Bool) -> [String] {
        var args = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                    "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15"]
        args += passwordOnly ? KeyInstaller.passwordOnlyOptions : ["-o", "BatchMode=yes"]
        return args + [kind.flag, spec, hostAlias]
    }
}

/// Список туннелей в Application Support (не в ~/.ssh/config: там пробросы
/// поднимались бы при каждом `ssh` на хост и конфликтовали бы по портам).
public struct TunnelStore: Sendable {
    public var url: URL

    public init(url: URL = TunnelStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        RelayaPaths.supportDirectory.appending(path: "tunnels.json")
    }

    public func load() -> [Tunnel] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Tunnel].self, from: data)) ?? []
    }

    public func save(_ tunnels: [Tunnel]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tunnels).write(to: url, options: .atomic)
    }
}
