import Foundation

/// Окружение хоста — задаёт цветовую метку в UI.
public enum HostEnvironment: String, Sendable, CaseIterable {
    case prod, staging, dev
}

/// Хост из `~/.ssh/config`. Relaya не хранит хосты у себя — это проекция конфига.
public struct SSHHost: Identifiable, Hashable, Sendable {
    public var id: String { alias }

    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    /// Метаданные Relaya из комментария `# relaya: group=prod env=prod` перед блоком Host.
    public var group: String?
    public var environment: HostEnvironment?

    public init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        group: String? = nil,
        environment: HostEnvironment? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.group = group
        self.environment = environment
    }

    /// Подпись `user@hostname:port` для списка хостов.
    public var subtitle: String {
        var s = hostName ?? alias
        if let user { s = "\(user)@\(s)" }
        if let port, port != 22 { s += ":\(port)" }
        return s
    }

    /// Вход по ключу явно настроен в конфиге.
    public var usesKey: Bool { identityFile != nil }
}
