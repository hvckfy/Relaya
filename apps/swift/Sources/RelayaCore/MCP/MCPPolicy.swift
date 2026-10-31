import Foundation
import RelayaRust

/// Права AI-агентов на хосты. Хранится в Application Support, редактируется в приложении.
public struct MCPPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case off, readOnly, confirm, trusted

        public var title: String {
            switch self {
            case .off: L("Нет доступа")
            case .readOnly: L("Только чтение")
            case .confirm: L("С подтверждением")
            case .trusted: L("Доверенный")
            }
        }
    }

    public var enabled: Bool
    public var defaultMode: Mode
    public var hosts: [String: Mode]
    /// Шаблоны команд (как в shell: `systemctl restart *`), которые выполняются без подтверждения.
    /// Ключ `*` — для всех хостов. Optional — старые mcp.json читаются.
    public var allow: [String: [String]]?
    /// Шаблоны, которые запрещены всегда, даже доверенному агенту (`rm -rf *`, `reboot*`).
    public var deny: [String: [String]]?
    /// Временный доступ: режим до указанного момента, потом — обычный.
    public var grants: [String: Grant]?

    public struct Grant: Codable, Equatable, Sendable {
        public var mode: Mode
        public var until: Date
        public init(mode: Mode, until: Date) {
            self.mode = mode
            self.until = until
        }
    }

    public init(enabled: Bool = true, defaultMode: Mode = .confirm, hosts: [String: Mode] = [:]) {
        self.enabled = enabled
        self.defaultMode = defaultMode
        self.hosts = hosts
    }

    // Логика — в Rust-ядре (`core/src/mcp.rs`), общем с Windows-клиентом.

    public func mode(for alias: String, now: Date = Date()) -> Mode {
        Mode(rust: mcpMode(policy: rust, alias: alias, nowRefSeconds: now.timeIntervalSinceReferenceDate))
    }

    /// Активный временный доступ к хосту.
    public func grant(for alias: String, now: Date = Date()) -> Grant? {
        mcpGrant(policy: rust, alias: alias, nowRefSeconds: now.timeIntervalSinceReferenceDate)
            .map { Grant(mode: Mode(rust: $0.mode), until: Date(timeIntervalSinceReferenceDate: $0.until)) }
    }

    public func allowPatterns(for alias: String) -> [String] { (allow?["*"] ?? []) + (allow?[alias] ?? []) }
    public func denyPatterns(for alias: String) -> [String] { (deny?["*"] ?? []) + (deny?[alias] ?? []) }

    /// Совпадение команды с шаблоном shell (`*`, `?`, `[…]`).
    public static func matches(_ command: String, pattern: String) -> Bool { mcpPatternMatches(command: command, pattern: pattern) }

    public func isDenied(_ command: String, on alias: String) -> Bool { mcpIsDenied(policy: rust, command: command, alias: alias) }

    /// Разрешено шаблоном без подтверждения. Цепочки команд шаблоном не разрешаются.
    public func isAllowed(_ command: String, on alias: String) -> Bool { mcpIsAllowed(policy: rust, command: command, alias: alias) }

    /// Можно ли выполнить команду в режиме «только чтение».
    public static func isReadOnly(_ command: String) -> Bool { mcpIsReadOnly(command: command) }

    /// Та же политика в Rust-ядре.
    var rust: McpPolicy {
        McpPolicy(enabled: enabled, defaultMode: defaultMode.rust, hosts: hosts.mapValues(\.rust), allow: allow, deny: deny,
                  grants: grants?.mapValues { McpGrant(mode: $0.mode.rust, until: $0.until.timeIntervalSinceReferenceDate) })
    }
}

extension MCPPolicy.Mode {
    var rust: McpMode {
        switch self {
        case .off: .off
        case .readOnly: .readOnly
        case .confirm: .confirm
        case .trusted: .trusted
        }
    }

    init(rust: McpMode) {
        switch rust {
        case .off: self = .off
        case .readOnly: self = .readOnly
        case .confirm: self = .confirm
        case .trusted: self = .trusted
        }
    }
}

public struct MCPPolicyStore: Sendable {
    public var url: URL

    public init(url: URL = MCPPolicyStore.directory.appending(path: "mcp.json")) {
        self.url = url
    }

    public static var directory: URL {
        RelayaPaths.supportDirectory
    }

    public func load() -> MCPPolicy {
        guard let data = try? Data(contentsOf: url) else { return MCPPolicy() }
        return (try? JSONDecoder().decode(MCPPolicy.self, from: data)) ?? MCPPolicy()
    }

    public func save(_ policy: MCPPolicy) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(policy).write(to: url, options: .atomic)
    }
}

/// Запись журнала вызовов агентов (JSON Lines).
public struct MCPLogEntry: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var client: String
    public var tool: String
    public var host: String
    public var detail: String
    public var decision: String
    public var exitCode: Int32?
    /// Сессия агента (один запуск `Relaya --mcp`).
    public var session: UUID?
    /// Команда могла что-то изменить (не «только чтение») и была выполнена.
    public var changes: Bool?
    /// Хвост вывода (до 2000 символов).
    public var output: String?

    public init(date: Date = Date(), client: String, tool: String, host: String, detail: String,
                decision: String, exitCode: Int32? = nil) {
        self.date = date
        self.client = client
        self.tool = tool
        self.host = host
        self.detail = detail
        self.decision = decision
        self.exitCode = exitCode
    }
}

public struct MCPLog: Sendable {
    public var url: URL

    public init(url: URL = MCPPolicyStore.directory.appending(path: "mcp-log.jsonl")) {
        self.url = url
    }

    public func append(_ entry: MCPLogEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    public func recent(_ limit: Int = 200) -> [MCPLogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).suffix(limit).reversed()
            .compactMap { try? decoder.decode(MCPLogEntry.self, from: Data($0.utf8)) }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Сводка «что изменил агент»: выполненные изменяющие команды, по сессиям, новые сверху.
    public struct SessionSummary: Identifiable, Sendable {
        public var id: UUID
        public var client: String
        public var started: Date
        public var hosts: [String]
        public var changes: [MCPLogEntry]
    }

    /// Сводка по сессиям — в Rust-ядре (`core/src/mcp.rs`); здесь — перевод к Swift-записям журнала.
    public static func summaries(_ entries: [MCPLogEntry]) -> [SessionSummary] {
        let f = ISO8601DateFormatter()
        let byID = Dictionary(entries.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let rust = entries.map { e in
            McpLogEntry(id: e.id.uuidString, date: f.string(from: e.date), client: e.client, tool: e.tool, host: e.host,
                        detail: e.detail, decision: e.decision, exitCode: e.exitCode, session: e.session?.uuidString,
                        changes: e.changes, output: e.output)
        }
        return mcpSummaries(entries: rust).compactMap { s in
            let changes = s.changes.compactMap { byID[$0.id] }
            guard let first = changes.first, let id = UUID(uuidString: s.id) else { return nil }
            return SessionSummary(id: id, client: s.client, started: first.date, hosts: s.hosts, changes: changes)
        }
    }

}
