import Foundation
import CryptoKit
import CommonCrypto

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

    // MARK: - Выгрузка в папку синхронизации

    /// Записать в `dir` то, что относится к профилю. Возвращает изменённые пути.
    @discardableResult
    public static func export(_ profile: Profile, paths: Paths = Paths(), passphrase: String? = nil, to dir: URL) throws -> [String] {
        let items = profile.effectiveItems
        var changed: [String] = []
        let configText = (try? String(contentsOf: paths.config, encoding: .utf8)) ?? ""
        let hosts = SSHConfigParser.parse(configText).filter { profile.scope.contains($0) && !$0.isGitService }
        let aliases = Set(hosts.map(\.alias))

        func write(_ data: Data, _ path: String) throws {
            let dest = dir.appending(path: path)
            if (try? Data(contentsOf: dest)) == data { return }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            changed.append(path)
        }

        // Своё добавляется к тому, что уже в папке, а не заменяет её: Mac без хостов не должен обнулить общий файл.
        if items.contains(.sshConfig) {
            let existing = (try? String(contentsOf: dir.appending(path: "ssh/config"), encoding: .utf8)) ?? ""
            let mine = SyncConfig.extract(configText, aliases: aliases)
            let merged = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? mine
                : SyncConfig.merge(local: existing, incoming: mine)
            try write(Data(merged.utf8), "ssh/config")
        }
        if items.contains(.snippets), let list: [Snippet] = load(paths.snippets) {
            try write(encode(withExisting(dir, "relaya/snippets.json", list).sorted { $0.id.uuidString < $1.id.uuidString }),
                      "relaya/snippets.json")
        }
        if items.contains(.tunnels), let list: [Tunnel] = load(paths.tunnels) {
            let mine = list.filter { aliases.contains($0.hostAlias) }
            try write(encode(withExisting(dir, "relaya/tunnels.json", mine).sorted { $0.id.uuidString < $1.id.uuidString }),
                      "relaya/tunnels.json")
        }
        if items.contains(.desktops), let list: [RemoteDesktop] = load(paths.desktops) {
            let mine = list.filter { d in
                profile.scope.allHosts || d.group.map { profile.scope.groups.contains($0) } ?? false
                    || d.viaSSHHost.map { aliases.contains($0) } ?? false
            }
            try write(encode(withExisting(dir, "relaya/desktops.json", mine).sorted { $0.id.uuidString < $1.id.uuidString }),
                      "relaya/desktops.json")
        }
        if items.contains(.agents), let data = try? Data(contentsOf: paths.mcp) {
            try write(data, "relaya/mcp.json")
        }
        if items.contains(.keys), let passphrase {
            let used = Set(hosts.compactMap(\.identityFile).map { SSHPaths.expand($0) })
            changed += try exportKeys(ssh: paths.ssh, passphrase: passphrase, only: used, to: dir)
        }
        return changed
    }

    // MARK: - Загрузка из папки синхронизации

    /// Влить в локальные файлы то, что лежит в `dir`. Возвращает пункты, которые изменились.
    @discardableResult
    public static func `import`(_ profile: Profile, paths: Paths = Paths(), passphrase: String? = nil, from dir: URL) throws -> [Item] {
        let items = profile.effectiveItems
        var changed: [Item] = []
        let fm = FileManager.default

        if items.contains(.sshConfig), let incoming = try? String(contentsOf: dir.appending(path: "ssh/config"), encoding: .utf8) {
            let local = (try? String(contentsOf: paths.config, encoding: .utf8)) ?? ""
            let merged = SyncConfig.merge(local: local, incoming: incoming)
            if merged != local {
                try fm.createDirectory(at: paths.ssh, withIntermediateDirectories: true)
                if fm.fileExists(atPath: paths.config.path) {
                    let bak = paths.ssh.appending(path: "config.bak")
                    try? fm.removeItem(at: bak)
                    try? fm.copyItem(at: paths.config, to: bak)
                }
                try Data(merged.utf8).write(to: paths.config, options: .atomic)
                chmod(paths.config.path, 0o600)
                changed.append(.sshConfig)
            }
        }
        if items.contains(.snippets), try mergeList(Snippet.self, from: dir.appending(path: "relaya/snippets.json"), into: paths.snippets) {
            changed.append(.snippets)
        }
        if items.contains(.tunnels), try mergeList(Tunnel.self, from: dir.appending(path: "relaya/tunnels.json"), into: paths.tunnels) {
            changed.append(.tunnels)
        }
        if items.contains(.desktops), try mergeList(RemoteDesktop.self, from: dir.appending(path: "relaya/desktops.json"), into: paths.desktops) {
            changed.append(.desktops)
        }
        if items.contains(.agents), let data = try? Data(contentsOf: dir.appending(path: "relaya/mcp.json")),
           (try? Data(contentsOf: paths.mcp)) != data {
            try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try data.write(to: paths.mcp, options: .atomic)
            changed.append(.agents)
        }
        if items.contains(.keys), let passphrase, !(try importKeys(ssh: paths.ssh, passphrase: passphrase, from: dir)).isEmpty {
            changed.append(.keys)
        }
        return changed
    }

    /// Список в папке + свои элементы (свои заменяют по id): выгрузка ничего не удаляет из общего.
    static func withExisting<T: Codable & Identifiable>(_ dir: URL, _ rel: String, _ mine: [T]) -> [T] where T.ID: Equatable {
        var out: [T] = load(dir.appending(path: rel)) ?? []
        for item in mine {
            if let i = out.firstIndex(where: { $0.id == item.id }) { out[i] = item } else { out.append(item) }
        }
        return out
    }

    /// Пришедшие элементы заменяют свои по id, новые добавляются, остальные локальные остаются.
    static func mergeList<T: Codable & Identifiable & Equatable>(_: T.Type, from incoming: URL, into local: URL) throws -> Bool
    where T.ID: Hashable {
        guard let theirs: [T] = load(incoming) else { return false }
        var mine: [T] = load(local) ?? []
        var changed = false
        for item in theirs {
            if let i = mine.firstIndex(where: { $0.id == item.id }) {
                if mine[i] != item { mine[i] = item; changed = true }
            } else {
                mine.append(item)
                changed = true
            }
        }
        guard changed else { return false }
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(mine).write(to: local, options: .atomic)
        return true
    }

    static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(value)
    }

    // MARK: - Ключи

    /// Приватные ключи (только `only`, если задан) → `keys/<имя>.relaya-key`, зашифрованные паролем синхронизации.
    @discardableResult
    public static func exportKeys(ssh: URL, passphrase: String, only: Set<String>? = nil, to dir: URL) throws -> [String] {
        let fm = FileManager.default
        let keysDir = dir.appending(path: "keys")
        var changed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: ssh.path)) ?? [] where name.hasSuffix(".pub") {
            let base = String(name.dropLast(4))
            let privateURL = ssh.appending(path: base)
            if let only, !only.contains(privateURL.path) { continue }
            guard let key = try? Data(contentsOf: privateURL) else { continue }
            try fm.createDirectory(at: keysDir, withIntermediateDirectories: true)
            let out = keysDir.appending(path: base + ".relaya-key")
            // Не перешифровываем без нужды: иначе каждый раз новый файл (соль) и лишний коммит.
            if let existing = try? Data(contentsOf: out), (try? KeyVault.decrypt(existing, passphrase: passphrase)) == key { continue }
            try KeyVault.encrypt(key, passphrase: passphrase).write(to: out, options: .atomic)
            try Data(contentsOf: ssh.appending(path: name)).write(to: keysDir.appending(path: name), options: .atomic)
            changed.append("keys/" + base)
        }
        return changed
    }

    /// Расшифровать ключи из папки синхронизации в `~/.ssh`; существующие файлы с тем же именем не трогаем.
    @discardableResult
    public static func importKeys(ssh: URL, passphrase: String, from dir: URL) throws -> [String] {
        let fm = FileManager.default
        let keysDir = dir.appending(path: "keys")
        var added: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: keysDir.path)) ?? [] where name.hasSuffix(".relaya-key") {
            let base = String(name.dropLast(".relaya-key".count))
            let dest = ssh.appending(path: base)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            let key = try KeyVault.decrypt(Data(contentsOf: keysDir.appending(path: name)), passphrase: passphrase)
            try fm.createDirectory(at: ssh, withIntermediateDirectories: true)
            try key.write(to: dest, options: .atomic)
            chmod(dest.path, 0o600)
            if let pub = try? Data(contentsOf: keysDir.appending(path: base + ".pub")) {
                try? pub.write(to: ssh.appending(path: base + ".pub"), options: .atomic)
            }
            added.append(base)
        }
        return added
    }
}

/// Блоки хостов `~/.ssh/config` для профилей синхронизации.
public enum SyncConfig {
    /// Только блоки нужных хостов (вместе с комментарием `# relaya:`), в порядке файла.
    public static func extract(_ text: String, aliases: Set<String>) -> String {
        let doc = SSHConfigDocument(text: text)
        var taken: [Range<Int>] = []
        for alias in aliases.sorted() {
            guard let b = doc.block(for: alias), !taken.contains(b.range) else { continue }
            taken.append(b.range)
        }
        let blocks = taken.sorted { $0.lowerBound < $1.lowerBound }.map { doc.lines[$0].joined(separator: "\n") }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    /// Пришедшие блоки заменяют одноимённые, новые добавляются в конец; остальной файл не меняется.
    public static func merge(local: String, incoming: String) -> String {
        var doc = SSHConfigDocument(text: local)
        let source = SSHConfigDocument(text: incoming)
        var seen = Set<String>()
        for host in SSHConfigParser.parse(incoming) where !seen.contains(host.alias) {
            guard let b = source.block(for: host.alias) else { continue }
            let block = Array(source.lines[b.range])
            for a in SSHConfigParser.aliases(in: SSHConfigParser.splitKeyValue(
                source.lines[b.hostLine].trimmingCharacters(in: .whitespaces)).1) { seen.insert(a) }
            doc.replaceOrAppend(alias: host.alias, with: block)
        }
        return doc.text
    }
}

/// Шифрование ключей для синхронизации: PBKDF2-SHA256 (600 000 итераций) → ChaCha20-Poly1305.
/// Формат: `RLYK1` · соль 16 байт · итерации (UInt32 BE) · nonce+шифртекст+тег.
public enum KeyVault {
    public struct Failure: Error, LocalizedError {
        public var errorDescription: String? { L("Не удалось расшифровать ключ: неверный пароль синхронизации или файл повреждён.") }
    }

    static let magic = Data("RLYK1".utf8)

    public static func encrypt(_ data: Data, passphrase: String, rounds: UInt32 = 600_000) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = try derive(passphrase, salt: salt, rounds: rounds)
        let sealed = try ChaChaPoly.seal(data, using: key)
        var r = rounds.bigEndian
        return magic + salt + Data(bytes: &r, count: 4) + sealed.combined
    }

    public static func decrypt(_ blob: Data, passphrase: String) throws -> Data {
        let b = [UInt8](blob)
        guard b.count > 5 + 16 + 4 + 28, Data(b[0..<5]) == magic else { throw Failure() }
        let salt = Data(b[5..<21])
        let rounds = b[21..<25].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let key = try derive(passphrase, salt: salt, rounds: rounds)
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: Data(b[25...])), using: key)
        } catch {
            throw Failure()
        }
    }

    static func derive(_ passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(passphrase.utf8)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        guard status == kCCSuccess else { throw Failure() }
        return SymmetricKey(data: out)
    }
}

/// Синхронизация через git-репозиторий пользователя: системный git и системный ssh (с ~/.ssh/config).
public struct GitSync: Sendable {
    public var repo: URL
    public var remote: String
    public static let branch = "main"

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
        /// Обменялись изменениями; `pulled` — пришли ли изменения с сервера.
        case synced(pulled: Bool)
        case conflict([Conflict])
    }

    public struct Conflict: Equatable, Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        public var mine: String
        public var theirs: String
    }

    @discardableResult
    func git(_ args: [String], allowFailure: Bool = false) async throws -> ProcessResult {
        // Без интерактивных запросов: ключ/агент из ~/.ssh/config или https-учётка из Keychain через git-credential.
        let env = ["GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=15",
                   "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Relaya", "GIT_AUTHOR_EMAIL": "relaya@localhost",
                   "GIT_COMMITTER_NAME": "Relaya", "GIT_COMMITTER_EMAIL": "relaya@localhost"]
        let r = try await ProcessRunner.run("/usr/bin/git", ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                                                              "-C", repo.path] + args, environment: env, timeout: .seconds(120))
        if !r.succeeded && !allowFailure {
            let msg = (r.stderr + r.stdout).split(whereSeparator: \.isNewline).last.map(String.init) ?? "git \(args.first ?? "")"
            throw Failure(message: msg)
        }
        return r
    }

    public var isSetUp: Bool { FileManager.default.fileExists(atPath: repo.appending(path: ".git").path) }

    /// Подготовить рабочую папку: клон удалённого репозитория (пустой — тоже) с веткой `main`.
    public func setUp() async throws {
        let fm = FileManager.default
        if isSetUp {
            try await git(["remote", "set-url", "origin", remote])
            return
        }
        try? fm.removeItem(at: repo)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", Self.branch])
        try await git(["remote", "add", "origin", remote])
        // Проверка доступа и подтягивание истории, если она уже есть.
        try await git(["fetch", "-q", "origin"])
        if try await remoteHasBranch() {
            try await git(["reset", "-q", "--hard", "origin/\(Self.branch)"])
        }
    }

    func remoteHasBranch() async throws -> Bool {
        let r = try await git(["rev-parse", "--verify", "-q", "origin/\(Self.branch)"], allowFailure: true)
        return r.succeeded
    }

    /// Один цикл: локальные изменения → коммит → забрать с сервера (слияние) → отправить.
    /// `exportLocal` кладёт локальные файлы в рабочую папку. Если пришли изменения (`.synced(pulled: true)`),
    /// вызывающий разносит их по местам сам — после возврата.
    public func sync(machine: String, exportLocal: @Sendable () throws -> Void) async throws -> Outcome {
        if try await inMerge() { return .conflict(try await conflicts()) }
        try exportLocal()
        try await git(["add", "-A"])
        let dirty = try await !git(["status", "--porcelain"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if dirty { try await git(["commit", "-q", "-m", "Relaya: \(machine)"]) }

        try await git(["fetch", "-q", "origin"])
        var pulled = false
        if try await remoteHasBranch() {
            let head = try await git(["rev-parse", "HEAD"], allowFailure: true).stdout
            let merge = try await git(["merge", "-q", "--no-edit", "origin/\(Self.branch)"], allowFailure: true)
            if !merge.succeeded {
                let c = try await conflicts()
                if !c.isEmpty { return .conflict(c) }
                throw Failure(message: merge.stderr.isEmpty ? "git merge" : merge.stderr)
            }
            pulled = try await git(["rev-parse", "HEAD"], allowFailure: true).stdout != head
        }
        let ahead = try await git(["rev-list", "--count", "origin/\(Self.branch)..HEAD"], allowFailure: true)
        let needsPush = !(try await remoteHasBranch()) || Int(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 > 0
        if needsPush, try await hasCommits() {
            try await git(["push", "-q", "origin", "HEAD:\(Self.branch)"])
        }
        return dirty || pulled || needsPush ? .synced(pulled: pulled) : .upToDate
    }

    func hasCommits() async throws -> Bool {
        try await git(["rev-parse", "--verify", "-q", "HEAD"], allowFailure: true).succeeded
    }

    func inMerge() async throws -> Bool {
        FileManager.default.fileExists(atPath: repo.appending(path: ".git/MERGE_HEAD").path)
    }

    /// Файлы с конфликтом: моя и их версия целиком — для показа рядом.
    public func conflicts() async throws -> [Conflict] {
        let names = try await git(["diff", "--name-only", "--diff-filter=U"]).stdout
            .split(whereSeparator: \.isNewline).map(String.init)
        var out: [Conflict] = []
        for path in names {
            let mine = try await git(["show", ":2:\(path)"], allowFailure: true).stdout
            let theirs = try await git(["show", ":3:\(path)"], allowFailure: true).stdout
            out.append(Conflict(path: path, mine: mine, theirs: theirs))
        }
        return out
    }

    /// Разрешить конфликт: для каждого файла — моя версия или с сервера; затем коммит и отправка.
    /// Разнести результат по местам вызывающий должен сам.
    public func resolve(_ choices: [String: Bool]) async throws {
        for (path, keepMine) in choices {
            try await git(["checkout", keepMine ? "--ours" : "--theirs", "--", path])
            try await git(["add", "--", path])
        }
        try await git(["commit", "-q", "--no-edit"])
        try await git(["push", "-q", "origin", "HEAD:\(Self.branch)"])
    }

    /// Отказаться от слияния и оставить своё состояние (без отправки).
    public func abortMerge() async throws {
        try await git(["merge", "--abort"], allowFailure: true)
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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imported = try Sync.import(profile, paths: paths, passphrase: passphrase, from: folder)
        try Sync.export(profile, paths: paths, passphrase: passphrase, to: folder)
        return imported
    }
}
