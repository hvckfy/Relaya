import Foundation

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

    /// `relaya-<alias>-<8 символов>`: только [a-z0-9-], чтобы имя не требовало кавычек ни в sh, ни в tmux.
    public static func sessionName(alias: String, id: UUID) -> String {
        hostPrefix(alias) + String(id.uuidString.lowercased().prefix(8))
    }

    public static func hostPrefix(_ alias: String) -> String {
        let safe = alias.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return prefix + String(safe) + "-"
    }

    /// Хук на отключение клиента: запомнить время, подождать `ttl` и убить сессию,
    /// если к ней так никто и не подключился (повторные отключения сдвигают срок).
    static func reaperHook(_ name: String, ttl: Int) -> String {
        let script = "tmux set -t \(name) @relaya_det $(date +%s); sleep \(ttl); "
            + "[ -n \"$(tmux list-clients -t \(name) 2>/dev/null)\" ] && exit 0; "
            + "d=$(tmux show -qv -t \(name) @relaya_det); "
            + "[ $(( $(date +%s) - ${d:-0} )) -ge \(max(ttl - 5, 0)) ] && tmux kill-session -t \(name)"
        return "run-shell -b '\(script)'"
    }

    /// Команда для `ssh -t host <cmd>`: подключиться к сессии или создать её; без tmux — обычный shell.
    public static func attachCommand(name: String, ttlMinutes: Int) -> String {
        let ttl = max(ttlMinutes, 1) * 60
        return "if command -v tmux >/dev/null 2>&1; then "
            + "exec tmux new-session -A -s \(name) \\; set -u -t \(name) @relaya_keep \\; "
            + "set-hook -t \(name) client-detached \(quote(reaperHook(name, ttl: ttl))); "
            + "else exec \"${SHELL:-sh}\" -l; fi"
    }

    /// Перед «оставить на сервере»: пометить и продлить срок до суток.
    public static func keepCommand(name: String) -> String {
        "tmux set -t \(name) @relaya_keep 1 \\; set-hook -t \(name) client-detached \(quote(reaperHook(name, ttl: keepSeconds)))"
    }

    public static let listCommand =
        "tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_created}|#{session_activity}|#{@relaya_det}|#{@relaya_keep}' 2>/dev/null | grep '^\(prefix)'; true"

    public static func killCommand(_ names: [String]) -> String {
        names.map { "tmux kill-session -t \(quote($0)) 2>/dev/null" }.joined(separator: "; ") + "; true"
    }

    public static func parse(_ output: String) -> [TmuxSession] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, f[0].hasPrefix(prefix),
                  let attached = Int(f[1]), let created = Double(f[2]), let activity = Double(f[3]) else { return nil }
            let det = f.count > 4 ? Double(f[4]).map { Date(timeIntervalSince1970: $0) } : nil
            return TmuxSession(name: f[0], attached: attached,
                               created: Date(timeIntervalSince1970: created),
                               activity: Date(timeIntervalSince1970: activity),
                               detachedAt: det, keep: f.count > 5 && f[5] == "1")
        }
    }

    /// Какие сессии хоста убрать: не подключённые, не открытые во вкладках и просроченные; сверх `cap` — самые старые.
    public static func stale(_ sessions: [TmuxSession], alias: String, open: Set<String>,
                             ttlMinutes: Int, now: Date = Date()) -> [String] {
        let mine = sessions.filter { $0.name.hasPrefix(hostPrefix(alias)) }
        let idle = mine.filter { $0.attached == 0 && !open.contains($0.name) }
        var kill = Set(idle.filter { s in
            let ttl = s.keep ? Double(keepSeconds) : Double(max(ttlMinutes, 1) * 60)
            return now.timeIntervalSince(s.detachedAt ?? s.activity) >= ttl
        }.map(\.name))
        let excess = mine.count - kill.count - cap
        if excess > 0 {
            let oldest = idle.filter { !kill.contains($0.name) }.sorted { $0.activity < $1.activity }
            kill.formUnion(oldest.prefix(excess).map(\.name))
        }
        return mine.map(\.name).filter(kill.contains)
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
