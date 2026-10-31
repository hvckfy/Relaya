import Foundation
import RelayaRust

/// Сессия tmux, созданная Relaya на сервере.
public struct TmuxSession: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var attached: Int
    public var created: Date
    public var activity: Date
    /// Когда от сессии отключился последний клиент (ставит хук).
    public var detachedAt: Date?
    /// «Отсоединить и оставить на сервере» — живёт дольше.
    public var keep: Bool

    public init(name: String, attached: Int, created: Date, activity: Date, detachedAt: Date? = nil, keep: Bool = false) {
        self.name = name
        self.attached = attached
        self.created = created
        self.activity = activity
        self.detachedAt = detachedAt
        self.keep = keep
    }
}

/// Постоянные сессии через tmux. Чтобы сессии не жили вечно:
/// закрытие вкладки — kill-session; обрыв — сессия остаётся, но хук на сервере убивает её,
/// если за `ttl` никто не подключился; при подключении к хосту убираются брошенные; не больше `cap` на хост.
public enum Tmux {
    public static let prefix = "relaya-"
    public static let keepSeconds = 24 * 3600
    public static let cap = 10

    // Логика — в Rust-ядре (`core/src/tmux.rs`).

    /// `relaya-<alias>-<8 символов>`: только [a-z0-9-], чтобы имя не требовало кавычек.
    public static func sessionName(alias: String, id: UUID) -> String { tmuxSessionName(alias: alias, id: id.uuidString) }

    public static func hostPrefix(_ alias: String) -> String { tmuxHostPrefix(alias: alias) }

    /// Команда для `ssh -t host <cmd>`: подключиться к сессии или создать её; без tmux — обычный shell.
    public static func attachCommand(name: String, ttlMinutes: Int) -> String {
        tmuxAttachCommand(name: name, ttlMinutes: Int64(ttlMinutes))
    }

    /// Подготовка сессии для control mode (обычным ssh, до `tmux -CC attach`).
    public static func prepareControlCommand(name: String, ttlMinutes: Int) -> String {
        tmuxPrepareControlCommand(name: name, ttlMinutes: Int64(ttlMinutes))
    }

    /// Перед «оставить на сервере»: пометить и продлить срок до суток.
    public static func keepCommand(name: String) -> String { tmuxKeepCommand(name: name) }

    public static var listCommand: String { tmuxListCommand() }

    public static func killCommand(_ names: [String]) -> String { tmuxKillCommand(names: names) }

    public static func parse(_ output: String) -> [TmuxSession] {
        tmuxParse(output: output).map { TmuxSession(rust: $0) }
    }

    /// Какие сессии хоста убрать: не подключённые, не открытые во вкладках и просроченные; сверх `cap` — самые старые.
    public static func stale(_ sessions: [TmuxSession], alias: String, open: Set<String>,
                             ttlMinutes: Int, now: Date = Date()) -> [String] {
        tmuxStale(sessions: sessions.map(\.rust), alias: alias, open: Array(open), ttlMinutes: Int64(ttlMinutes),
                  now: now.timeIntervalSince1970)
    }
}

extension TmuxSession {
    init(rust s: RelayaRust.TmuxSession) {
        self.init(name: s.name, attached: Int(s.attached), created: Date(timeIntervalSince1970: s.created),
                  activity: Date(timeIntervalSince1970: s.activity),
                  detachedAt: s.detachedAt.map { Date(timeIntervalSince1970: $0) }, keep: s.keep)
    }

    var rust: RelayaRust.TmuxSession {
        RelayaRust.TmuxSession(name: name, attached: Int64(attached), created: created.timeIntervalSince1970,
                               activity: activity.timeIntervalSince1970, detachedAt: detachedAt?.timeIntervalSince1970, keep: keep)
    }
}
