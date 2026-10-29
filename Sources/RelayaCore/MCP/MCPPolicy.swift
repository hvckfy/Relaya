import Foundation

/// Права AI-агентов на хосты. Хранится в Application Support, редактируется в приложении.
public struct MCPPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case off, readOnly, confirm, trusted

        public var title: String {
            switch self {
            case .off: "Нет доступа"
            case .readOnly: "Только чтение"
            case .confirm: "С подтверждением"
            case .trusted: "Доверенный"
            }
        }
    }

    public var enabled: Bool
    public var defaultMode: Mode
    public var hosts: [String: Mode]

    public init(enabled: Bool = true, defaultMode: Mode = .confirm, hosts: [String: Mode] = [:]) {
        self.enabled = enabled
        self.defaultMode = defaultMode
        self.hosts = hosts
    }

    public func mode(for alias: String) -> Mode {
        enabled ? (hosts[alias] ?? defaultMode) : .off
    }

    // MARK: - Только чтение

    /// Команды, которые ничего не меняют. Проверяется первое слово каждого звена конвейера.
    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "egrep", "zgrep", "less", "wc", "sort", "uniq", "cut", "awk", "sed",
        "df", "du", "free", "uptime", "uname", "hostname", "whoami", "id", "date", "ps", "pgrep", "top",
        "stat", "file", "find", "which", "lsblk", "lscpu", "lsof", "ss", "netstat", "ip", "ping", "dig",
        "nslookup", "journalctl", "dmesg", "env", "printenv", "echo", "pwd", "tree", "md5sum", "sha256sum",
        "ubus", "logread", "iwinfo", "sw_vers", "vm_stat", "nproc",
    ]
    /// Двухсловные команды, разрешённые в режиме чтения.
    static let readOnlyPairs: Set<String> = [
        "systemctl status", "systemctl list-units", "systemctl --failed", "systemctl is-active",
        "docker ps", "docker logs", "docker images", "docker inspect", "docker stats",
        "kubectl get", "kubectl describe", "kubectl logs", "git status", "git log", "git diff",
        "apt list", "dpkg -l", "rpm -qa", "opkg list-installed", "uci show", "nginx -t",
    ]

    /// Можно ли выполнить команду в режиме «только чтение».
    public static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Перенаправления, подстановки, последовательности и фон — запрещены.
        for bad in [";", "&", ">", "<", "`", "$(", "\n", "\\"] where trimmed.contains(bad) { return false }
        for segment in trimmed.split(separator: "|") {
            let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = words.first else { return false }
            if first == "sudo" { return false }
            // sed/awk/find умеют писать файлы — только безопасные формы.
            if first == "sed", words.contains(where: { $0.hasPrefix("-i") }) { return false }
            if first == "find", words.contains(where: { ["-delete", "-exec", "-execdir", "-fprint", "-ok"].contains($0) }) { return false }
            if first == "awk", segment.contains("system(") { return false }
            let pair = words.prefix(2).joined(separator: " ")
            if !readOnlyCommands.contains(first) && !readOnlyPairs.contains(pair) { return false }
        }
        return true
    }
}

public struct MCPPolicyStore: Sendable {
    public var url: URL

    public init(url: URL = MCPPolicyStore.directory.appending(path: "mcp.json")) {
        self.url = url
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Relaya")
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
}
