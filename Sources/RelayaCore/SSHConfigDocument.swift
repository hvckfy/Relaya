import Foundation

/// Построчная модель `~/.ssh/config` для правок.
///
/// Меняет только блок нужного хоста: остальной файл, комментарии и незнакомые
/// директивы внутри блока сохраняются как есть.
public struct SSHConfigDocument: Sendable {
    public private(set) var lines: [String]

    /// Директивы, которыми управляет редактор Relaya. Остальные строки блока не трогаются.
    static let managedKeys: Set<String> = [
        "hostname", "user", "port", "identityfile", "proxyjump",
        "forwardagent", "serveraliveinterval", "compression", "usekeychain", "addkeystoagent",
    ]

    public init(text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
    }

    public var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    /// Где лежит блок хоста.
    public struct Block: Sendable, Equatable {
        /// Строки блока, включая комментарий `# relaya:` над ним.
        public var range: Range<Int>
        /// Индекс строки `Host`.
        public var hostLine: Int
        /// Блок объявлен вместе с другими алиасами (`Host a b`) — правка разорвала бы его.
        public var isShared: Bool
    }

    public func block(for alias: String) -> Block? {
        for (i, raw) in lines.enumerated() {
            let (key, value) = SSHConfigParser.splitKeyValue(raw.trimmingCharacters(in: .whitespaces))
            guard key == "host" else { continue }
            let aliases = SSHConfigParser.aliases(in: value)
            guard aliases.contains(alias) else { continue }

            var end = i + 1
            while end < lines.count {
                let (k, _) = SSHConfigParser.splitKeyValue(lines[end].trimmingCharacters(in: .whitespaces))
                if k == "host" || k == "match" { break }
                end += 1
            }
            // Хвостовые пустые строки и мета следующего блока к этому хосту не относятся.
            while end > i + 1 {
                let t = lines[end - 1].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || SSHConfigParser.parseMeta(t) != nil { end -= 1 } else { break }
            }
            var start = i
            if i > 0, SSHConfigParser.parseMeta(lines[i - 1].trimmingCharacters(in: .whitespaces)) != nil {
                start = i - 1
            }
            return Block(range: start..<end, hostLine: i, isShared: aliases.count > 1)
        }
        return nil
    }

    /// Строки, которые сейчас занимает хост (для превью).
    public func currentLines(for alias: String) -> [String] {
        guard let block = block(for: alias) else { return [] }
        return Array(lines[block.range])
    }

    /// Строки блока после сохранения `host`. Незнакомые директивы из старого блока сохраняются.
    public func renderedLines(for host: SSHHost, replacing originalAlias: String?) -> [String] {
        var out: [String] = []
        var meta: [String] = []
        if let g = host.group, !g.isEmpty { meta.append("group=\(SSHConfigParser.metaValue(g))") }
        let tags = SSHConfigParser.splitTags(host.tags.joined(separator: ","))
        if !tags.isEmpty { meta.append("tags=\(SSHConfigParser.metaValue(tags.joined(separator: ",")))") }
        if let c = host.color, !c.isEmpty { meta.append("color=\(c)") }
        if let os = host.os { meta.append("os=\(os.rawValue)") }
        if !meta.isEmpty { out.append("# relaya: " + meta.joined(separator: " ")) }

        out.append("Host \(host.alias)")
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { out.append("    \(key) \(value)") }
        }
        add("HostName", host.hostName)
        add("User", host.user)
        add("Port", host.port.map(String.init))
        add("IdentityFile", host.identityFile)
        if host.identityFile?.isEmpty == false {
            // passphrase ключа — в системный Keychain, ключ — в ssh-agent при первом использовании.
            add("UseKeychain", "yes")
            add("AddKeysToAgent", "yes")
        }
        add("ProxyJump", host.proxyJump)
        if host.forwardAgent == true { add("ForwardAgent", "yes") }
        add("ServerAliveInterval", host.serverAliveInterval.map(String.init))
        if host.compression == true { add("Compression", "yes") }

        if let originalAlias, let block = block(for: originalAlias) {
            for raw in lines[(block.hostLine + 1)..<block.range.upperBound] {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                let (key, _) = SSHConfigParser.splitKeyValue(t)
                if t.hasPrefix("#") || !Self.managedKeys.contains(key) { out.append(raw) }
            }
        }
        return out
    }

    public enum EditError: Error, Equatable, LocalizedError {
        case aliasTaken(String)
        case sharedBlock(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .aliasTaken(let a): "Хост «\(a)» уже есть в ~/.ssh/config"
            case .sharedBlock(let a): "«\(a)» объявлен вместе с другими алиасами — отредактируйте ~/.ssh/config вручную"
            case .notFound(let a): "Хост «\(a)» не найден в ~/.ssh/config"
            }
        }
    }

    /// Добавляет хост (`originalAlias == nil`) или заменяет блок существующего.
    public mutating func upsert(_ host: SSHHost, originalAlias: String?) throws {
        if host.alias != originalAlias, block(for: host.alias) != nil {
            throw EditError.aliasTaken(host.alias)
        }
        let rendered = renderedLines(for: host, replacing: originalAlias)
        if let originalAlias {
            guard let block = block(for: originalAlias) else { throw EditError.notFound(originalAlias) }
            guard !block.isShared else { throw EditError.sharedBlock(originalAlias) }
            lines.replaceSubrange(block.range, with: rendered)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append(contentsOf: rendered)
        }
    }

    public mutating func remove(alias: String) throws {
        guard let block = block(for: alias) else { throw EditError.notFound(alias) }
        guard !block.isShared else { throw EditError.sharedBlock(alias) }
        var range = block.range
        // Убираем и пустую строку-разделитель после блока, чтобы не копились пробелы.
        if range.upperBound < lines.count, lines[range.upperBound].trimmingCharacters(in: .whitespaces).isEmpty {
            range = range.lowerBound..<(range.upperBound + 1)
        }
        lines.removeSubrange(range)
    }
}
