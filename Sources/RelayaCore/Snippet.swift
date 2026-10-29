import Foundation

/// Сохранённая команда. Переменные — `{{имя}}`, их значения спрашиваются перед вставкой.
public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var command: String
    public var tags: [String]

    public init(name: String, command: String, tags: [String] = []) {
        self.name = name
        self.command = command
        self.tags = tags
    }

    /// Имена переменных в порядке появления, без повторов.
    public var variables: [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([\p{L}_][^{}\s]*)\s*\}\}"#) else { return [] }
        let ns = command as NSString
        var seen = Set<String>()
        return regex.matches(in: command, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let name = ns.substring(with: m.range(at: 1))
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// Команда с подставленными значениями; незаполненные переменные остаются как есть.
    public func filled(_ values: [String: String]) -> String {
        var out = command
        for name in variables {
            guard let value = values[name] else { continue }
            out = out.replacingOccurrences(of: #"\{\{\s*\#(NSRegularExpression.escapedPattern(for: name))\s*\}\}"#,
                                           with: NSRegularExpression.escapedTemplate(for: value),
                                           options: .regularExpression)
        }
        return out
    }

    public static let examples: [Snippet] = [
        Snippet(name: "Логи сервиса", command: "journalctl -u {{service}} -n 200 --no-pager", tags: ["linux"]),
        Snippet(name: "Кто слушает порт", command: "ss -tlnp | grep :{{port}}", tags: ["сеть"]),
        Snippet(name: "Самые большие каталоги", command: "du -xh {{path}} 2>/dev/null | sort -rh | head -n 20"),
        Snippet(name: "Docker: контейнеры", command: "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'",
                tags: ["docker"]),
    ]
}

public struct SnippetStore: Sendable {
    public var url: URL

    public init(url: URL = SnippetStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Relaya/snippets.json")
    }

    /// При первом запуске — несколько примеров.
    public func load() -> [Snippet] {
        guard let data = try? Data(contentsOf: url) else { return Snippet.examples }
        return (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
    }

    public func save(_ snippets: [Snippet]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snippets).write(to: url, options: .atomic)
    }
}
