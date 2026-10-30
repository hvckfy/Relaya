import Foundation

/// Хост из `~/.ssh/config`. Relaya не хранит хосты у себя — это проекция конфига.
public struct SSHHost: Identifiable, Hashable, Sendable {
    public var id: String { alias }

    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?
    public var forwardAgent: Bool?
    public var serverAliveInterval: Int?
    public var compression: Bool?

    /// Метаданные Relaya из комментария `# relaya: group=работа tags=prod,db color=orange` перед блоком Host.
    public var group: String?
    /// Метки для фильтрации; порядок — как ввёл пользователь.
    public var tags: [String]
    public var color: String?
    /// ОС сервера — определяется автоматически после подключения.
    public var os: ServerOS?
    /// Постоянная сессия через tmux (`tmux=on`): переподключение возвращает в неё же.
    public var tmux = false

    public init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        forwardAgent: Bool? = nil,
        serverAliveInterval: Int? = nil,
        compression: Bool? = nil,
        group: String? = nil,
        tags: [String] = [],
        color: String? = nil,
        os: ServerOS? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.forwardAgent = forwardAgent
        self.serverAliveInterval = serverAliveInterval
        self.compression = compression
        self.group = group
        self.tags = tags
        self.color = color
        self.os = os
    }

    /// Запись для git-хостинга (GitHub, GitLab, Bitbucket…), а не сервер: в список хостов не попадает.
    public var isGitService: Bool {
        let name = (hostName ?? alias).lowercased()
        let known = ["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
                     "codeberg.org", "gitea.com", "ssh.github.com", "altssh.gitlab.com", "altssh.bitbucket.org"]
        return user == "git" || known.contains(name)
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
