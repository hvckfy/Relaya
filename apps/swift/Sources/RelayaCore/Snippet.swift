import Foundation
import RelayaRust

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

    /// Имена переменных в порядке появления, без повторов (Rust-ядро, `core/src/models.rs`).
    public var variables: [String] { snippetVariables(command: command) }

    /// Команда с подставленными значениями; незаполненные переменные остаются как есть.
    public func filled(_ values: [String: String]) -> String { snippetFilled(command: command, values: values) }

    public static let examples: [Snippet] = [
        Snippet(name: L("Логи сервиса"), command: "journalctl -u {{service}} -n 200 --no-pager", tags: ["linux"]),
        Snippet(name: L("Кто слушает порт"), command: "ss -tlnp | grep :{{port}}", tags: [L("сеть")]),
        Snippet(name: L("Самые большие каталоги"), command: "du -xh {{path}} 2>/dev/null | sort -rh | head -n 20"),
        Snippet(name: L("Docker: контейнеры"), command: "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'",
                tags: ["docker"]),
    ]
}

public struct SnippetStore: Sendable {
    public var url: URL

    public init(url: URL = SnippetStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        RelayaPaths.supportDirectory.appending(path: "snippets.json")
    }

    /// При первом запуске — несколько примеров.
    public func load() -> [Snippet] {
        StoreRecovery.load([Snippet].self, from: url, missing: Snippet.examples)
    }

    public func save(_ snippets: [Snippet]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snippets).write(to: url, options: .atomic)
    }
}
