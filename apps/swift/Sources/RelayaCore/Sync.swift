import Foundation
import RelayaRust

/// Личная синхронизация Relaya без своего облака: git-репозиторий пользователя (основной вариант)
/// или папка в iCloud Drive. Профилей может быть несколько — у каждого свой репозиторий и свой набор хостов
/// (все, выбранные группы, выбранные хосты). Пароли не синхронизируются никогда; ключи — только по выбору,
/// только используемые хостами профиля и зашифрованными.
///
/// Слияние без удалений: пришедшие блоки хостов, туннели, сниппеты и столы добавляются или заменяют свои
/// по алиасу/идентификатору, а всё, чего нет в профиле, остаётся как было.
public enum Sync {
    public enum Item: String, Codable, CaseIterable, Sendable, Identifiable {
        case sshConfig, snippets, tunnels, desktops, agents, keys
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .sshConfig: L("Хосты (~/.ssh/config)")
            case .snippets: L("Сниппеты")
            case .tunnels: L("Туннели хостов профиля")
            case .desktops: L("Удалённые столы")
            case .agents: L("Права агентов (MCP)")
            case .keys: L("SSH-ключи хостов (зашифрованные)")
            }
        }
    }

    public enum Backend: String, Codable, Sendable, CaseIterable {
        case git, iCloud
    }

    /// Какие хосты относятся к профилю.
    public struct Scope: Codable, Equatable, Sendable {
        public var allHosts = true
        public var groups: Set<String> = []
        public var hosts: Set<String> = []
        public init(allHosts: Bool = true, groups: Set<String> = [], hosts: Set<String> = []) {
            self.allHosts = allHosts
            self.groups = groups
            self.hosts = hosts
        }

        public func contains(_ h: SSHHost) -> Bool {
            allHosts || hosts.contains(h.alias) || (h.group.map { groups.contains($0) } ?? false)
        }
    }

    public struct Profile: Codable, Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var backend: Backend = .git
        /// `git@server:relaya.git`, `alias:relaya.git` (алиас из ~/.ssh/config), `https://…`.
        public var remote: String = ""
        public var scope = Scope()
        public var items: Set<Item> = [.sshConfig, .snippets, .tunnels, .desktops]
        public var auto = true
        public var enabled = true
        public init(name: String) { self.name = name }

        /// Сниппеты и права агентов не привязаны к хостам — только для профиля «все хосты».
        public var effectiveItems: Set<Item> {
            scope.allHosts ? items : items.subtracting([.snippets, .agents])
        }
    }

    /// Где лежат локальные файлы.
    public struct Paths: Sendable {
        public var ssh: URL
        public var support: URL
        public init(ssh: URL = RelayaPaths.sshDirectory, support: URL = RelayaPaths.supportDirectory) {
            self.ssh = ssh
            self.support = support
        }
        var config: URL { ssh.appending(path: "config") }
        var snippets: URL { support.appending(path: "snippets.json") }
        var tunnels: URL { support.appending(path: "tunnels.json") }
        var desktops: URL { support.appending(path: "desktops.json") }
        var mcp: URL { support.appending(path: "mcp.json") }
    }

    // MARK: - Выгрузка и загрузка (Rust-ядро, `core/src/sync.rs`)

    /// Записать в `dir` то, что относится к профилю. Возвращает изменённые пути.
    @discardableResult
    public static func export(_ profile: Profile, paths: Paths = Paths(), passphrase: String? = nil, to dir: URL) throws -> [String] {
        try syncExport(profile: profile.rust, paths: paths.rust, passphrase: passphrase, dir: dir.path)
    }

    /// Влить в локальные файлы то, что лежит в `dir`. Возвращает пункты, которые изменились.
    @discardableResult
    public static func `import`(_ profile: Profile, paths: Paths = Paths(), passphrase: String? = nil, from dir: URL) throws -> [Item] {
        try syncImport(profile: profile.rust, paths: paths.rust, passphrase: passphrase, dir: dir.path).map(Item.init(rust:))
    }

    static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Расшифровать ключи из папки синхронизации в `~/.ssh`; существующие файлы с тем же именем не трогаем.
    @discardableResult
    public static func importKeys(ssh: URL, passphrase: String, from dir: URL) throws -> [String] {
        // Через профиль «только ключи»: ядро разносит то же, что при обычной синхронизации.
        var p = Profile(name: "keys")
        p.items = [.keys]
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: ssh.path)) ?? [])
        _ = try syncImport(profile: p.rust, paths: SyncPaths(ssh: ssh.path, support: ssh.path), passphrase: passphrase, dir: dir.path)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: ssh.path)) ?? [])
        return after.subtracting(before).filter { !$0.hasSuffix(".pub") }.sorted()
    }
}

extension Sync.Item {
    var rust: SyncItem {
        switch self {
        case .sshConfig: .sshConfig
        case .snippets: .snippets
        case .tunnels: .tunnels
        case .desktops: .desktops
        case .agents: .agents
        case .keys: .keys
        }
    }

    init(rust: SyncItem) {
        switch rust {
        case .sshConfig: self = .sshConfig
        case .snippets: self = .snippets
        case .tunnels: self = .tunnels
        case .desktops: self = .desktops
        case .agents: self = .agents
        case .keys: self = .keys
        }
    }
}

extension Sync.Profile {
    var rust: SyncProfile {
        SyncProfile(id: id.uuidString, name: name, backend: backend == .git ? .git : .iCloud, remote: remote,
                    scope: SyncScope(allHosts: scope.allHosts, groups: scope.groups.sorted(), hosts: scope.hosts.sorted()),
                    items: Sync.Item.allCases.filter(items.contains).map(\.rust), auto: auto, enabled: enabled)
    }
}

extension Sync.Paths {
    var rust: SyncPaths { SyncPaths(ssh: ssh.path, support: support.path) }
}

/// Блоки хостов `~/.ssh/config` для профилей синхронизации.
public enum SyncConfig {
    /// Только блоки нужных хостов (вместе с комментарием `# relaya:`), в порядке файла.
    public static func extract(_ text: String, aliases: Set<String>) -> String {
        configExtract(text: text, aliasesIn: Array(aliases))
    }

    /// Пришедшие блоки заменяют одноимённые, новые добавляются в конец; остальной файл не меняется.
    public static func merge(local: String, incoming: String) -> String {
        configMerge(local: local, incoming: incoming)
    }
}

/// Шифрование ключей для синхронизации: PBKDF2-SHA256 → ChaCha20-Poly1305, формат RLYK1.
public enum KeyVault {
    public struct Failure: Error, LocalizedError {
        public var errorDescription: String? { L("Не удалось расшифровать ключ: неверный пароль синхронизации или файл повреждён.") }
    }

    public static func encrypt(_ data: Data, passphrase: String, rounds: UInt32 = 600_000) throws -> Data {
        keyEncrypt(data: data, passphrase: passphrase, rounds: rounds)
    }

    public static func decrypt(_ blob: Data, passphrase: String) throws -> Data {
        do { return try keyDecrypt(blob: blob, passphrase: passphrase) } catch { throw Failure() }
    }
}

/// Синхронизация через git-репозиторий пользователя: системный git и ssh (с ~/.ssh/config). Сам цикл — в ядре.
public struct GitSync: Sendable {
    public var repo: URL
    public var remote: String

    public init(repo: URL = RelayaPaths.supportDirectory.appending(path: "sync"), remote: String) {
        self.repo = repo
        self.remote = remote
    }

    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    public enum Outcome: Equatable, Sendable {
        case upToDate
        /// Обменялись изменениями; `imported` — что пришло с сервера и разнесено по местам.
        case synced(pulled: Bool, imported: [Sync.Item])
        case conflict([Conflict])
    }

    public struct Conflict: Equatable, Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        public var mine: String
        public var theirs: String
    }

    /// Ядро запускает git синхронно — не в главном потоке.
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached { do { return try body() } catch let e as CoreError { throw Failure(message: "\(e)") } }.value
    }

    /// Один цикл: выгрузка → коммит → слияние с сервером → разнос пришедшего → отправка.
    /// Типы ядра не Sendable — переводим их туда и обратно внутри фонового потока.
    public func sync(machine: String, profile: Sync.Profile, paths: Sync.Paths = Sync.Paths(),
                     passphrase: String? = nil) async throws -> Outcome {
        let (repo, remote) = (repo.path, remote)
        return try await offMain { () -> Outcome in
            switch try gitSync(repo: repo, remote: remote, machine: machine, profile: profile.rust, paths: paths.rust,
                               passphrase: passphrase) {
            case .upToDate: return .upToDate
            case .synced(let pulled, let imported): return .synced(pulled: pulled, imported: imported.map(Sync.Item.init(rust:)))
            case .conflict(let c): return .conflict(c.map { Conflict(path: $0.path, mine: $0.mine, theirs: $0.theirs) })
            }
        }
    }

    /// Разрешить конфликт (`true` — моя версия), закоммитить, разнести и отправить.
    public func resolve(_ choices: [String: Bool], profile: Sync.Profile, paths: Sync.Paths = Sync.Paths(),
                        passphrase: String? = nil) async throws -> [Sync.Item] {
        let repo = repo.path
        return try await offMain {
            try gitResolve(repo: repo, keepMine: choices, profile: profile.rust, paths: paths.rust, passphrase: passphrase)
                .map(Sync.Item.init(rust:))
        }
    }

    /// Отказаться от слияния и оставить своё состояние (без отправки).
    public func abortMerge() async throws {
        let repo = repo.path
        _ = try await offMain { gitAbortMerge(repo: repo) }
    }
}

/// Папка в iCloud Drive вместо git: сначала влить пришедшее, потом выгрузить своё (слияние без удалений).
public enum FolderSync {
    public static var iCloudRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    }

    public static var iCloudAvailable: Bool { FileManager.default.fileExists(atPath: iCloudRoot.path) }

    public static func folder(for profile: Sync.Profile) -> URL {
        iCloudRoot.appending(path: "Relaya Sync").appending(path: profile.name.replacingOccurrences(of: "/", with: "-"))
    }

    @discardableResult
    public static func sync(_ profile: Sync.Profile, paths: Sync.Paths = Sync.Paths(), passphrase: String? = nil,
                            folder: URL) throws -> [Sync.Item] {
        try folderSync(profile: profile.rust, paths: paths.rust, passphrase: passphrase, folder: folder.path).map(Sync.Item.init(rust:))
    }
}
