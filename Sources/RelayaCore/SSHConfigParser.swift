import Foundation

/// Читает `~/.ssh/config` в список хостов.
///
/// Поддерживается базовое подмножество: блоки `Host` с конкретными алиасами и ключи
/// HostName, User, Port, IdentityFile, ProxyJump, ForwardAgent, ServerAliveInterval,
/// Compression. Шаблоны (`*`, `?`, `!`), `Match` и `Include` пока пропускаются.
public enum SSHConfigParser {
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config")
    }

    public static func load(from url: URL = defaultConfigURL) throws -> [SSHHost] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return parse(try String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var current: [SSHHost] = []
        var pendingMeta = Meta()
        var inMatch = false

        func flush() {
            hosts.append(contentsOf: current)
            current = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                if let meta = parseMeta(line) { pendingMeta = meta }
                continue
            }

            let (key, value) = splitKeyValue(line)
            switch key {
            case "host":
                flush()
                inMatch = false
                current = aliases(in: value)
                    .filter { !isPattern($0) }
                    .map {
                        SSHHost(alias: $0, group: pendingMeta.group,
                                environment: pendingMeta.env, color: pendingMeta.color)
                    }
                pendingMeta = Meta()
            case "match":
                flush()
                inMatch = true
            default:
                guard !inMatch else { continue }
                for i in current.indices {
                    apply(key: key, value: value, to: &current[i])
                }
            }
        }
        flush()
        return hosts
    }

    // MARK: - Общие помощники (используются и SSHConfigDocument)

    struct Meta {
        var group: String?
        var env: HostEnvironment?
        var color: String?
    }

    static func aliases(in value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func isPattern(_ alias: String) -> Bool {
        alias.contains(where: { "*?!".contains($0) })
    }

    private static func apply(key: String, value: String, to host: inout SSHHost) {
        // В ssh_config побеждает первое значение — повторы не перезаписывают.
        switch key {
        case "hostname" where host.hostName == nil: host.hostName = value
        case "user" where host.user == nil: host.user = value
        case "port" where host.port == nil: host.port = Int(value)
        case "identityfile" where host.identityFile == nil: host.identityFile = value
        case "proxyjump" where host.proxyJump == nil: host.proxyJump = value
        case "forwardagent" where host.forwardAgent == nil: host.forwardAgent = value.lowercased() == "yes"
        case "serveraliveinterval" where host.serverAliveInterval == nil: host.serverAliveInterval = Int(value)
        case "compression" where host.compression == nil: host.compression = value.lowercased() == "yes"
        default: break
        }
    }

    /// `Key value`, `Key=value` или `Key = "value"`.
    static func splitKeyValue(_ line: String) -> (String, String) {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let r = line.rangeOfCharacter(from: separators) else { return (line.lowercased(), "") }
        let key = String(line[..<r.lowerBound]).lowercased()
        var value = String(line[r.upperBound...]).trimmingCharacters(in: separators)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    /// `# relaya: group=prod env=prod color=orange`
    static func parseMeta(_ line: String) -> Meta? {
        let body = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        guard body.lowercased().hasPrefix("relaya:") else { return nil }
        var meta = Meta()
        for pair in body.dropFirst("relaya:".count).split(whereSeparator: \.isWhitespace) {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "group": meta.group = kv[1]
            case "env": meta.env = HostEnvironment(rawValue: kv[1].lowercased())
            case "color": meta.color = kv[1].lowercased()
            default: break
            }
        }
        return meta
    }
}
