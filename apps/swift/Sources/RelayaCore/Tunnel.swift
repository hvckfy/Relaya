import Foundation
import RelayaRust

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
            case .local: L("Локальный (-L)")
            case .remote: L("Удалённый (-R)")
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

    /// Тот же туннель в Rust-ядре.
    var rust: RelayaRust.Tunnel {
        RelayaRust.Tunnel(id: id.uuidString, name: name, hostAlias: hostAlias,
                          kind: { switch kind { case .local: .local; case .remote: .remote; case .dynamic: .dynamic } }(),
                          listenPort: Int64(listenPort), targetHost: targetHost, targetPort: Int64(targetPort), autoStart: autoStart)
    }

    /// Спецификация проброса для ssh: `8080:localhost:80` или `1080`.
    public var spec: String { tunnelSpec(t: rust) }

    /// Короткое описание: `localhost:8080 → db:5432 через web`.
    public var summary: String {
        switch kind {
        case .local: L("localhost:%@ → %@:%@ через %@", "\(listenPort)", "\(targetHost)", "\(targetPort)", "\(hostAlias)")
        case .remote: L("%@:%@ → %@:%@ на этом Mac", "\(hostAlias)", "\(listenPort)", "\(targetHost)", "\(targetPort)")
        case .dynamic: L("SOCKS localhost:%@ через %@", "\(listenPort)", "\(hostAlias)")
        }
    }

    public var validationError: String? {
        if hostAlias.isEmpty { return L("Выберите хост") }
        if !(1...65535).contains(listenPort) { return L("Порт — число от 1 до 65535") }
        if kind != .dynamic {
            if targetHost.trimmingCharacters(in: .whitespaces).isEmpty { return L("Укажите адрес назначения") }
            if !(1...65535).contains(targetPort) { return L("Порт назначения — число от 1 до 65535") }
        }
        return nil
    }

    /// Аргументы `ssh` без секретов. Пароль, если нужен, — через askpass.
    public func sshArguments(passwordOnly: Bool) -> [String] { tunnelSshArguments(t: rust, passwordOnly: passwordOnly) }
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
        StoreRecovery.load([Tunnel].self, from: url, missing: [])
    }

    public func save(_ tunnels: [Tunnel]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tunnels).write(to: url, options: .atomic)
    }
}
