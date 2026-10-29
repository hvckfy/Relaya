import Foundation

/// Читает `~/.ssh/config` в список хостов.
///
/// Поддерживается базовое подмножество: блоки `Host` с конкретными алиасами и ключи
/// HostName, User, Port, IdentityFile, ProxyJump. Шаблоны (`*`, `?`, `!`), `Match`
/// и `Include` пока пропускаются.
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
        var pendingMeta: (group: String?, env: HostEnvironment?) = (nil, nil)
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
                current = value
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { !$0.contains(where: { "*?!".contains($0) }) }
                    .map { SSHHost(alias: $0, group: pendingMeta.group, environment: pendingMeta.env) }
                pendingMeta = (nil, nil)
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

    private static func apply(key: String, value: String, to host: inout SSHHost) {
        // В ssh_config побеждает первое значение — повторы не перезаписывают.
        switch key {
        case "hostname" where host.hostName == nil: host.hostName = value
        case "user" where host.user == nil: host.user = value
        case "port" where host.port == nil: host.port = Int(value)
        case "identityfile" where host.identityFile == nil: host.identityFile = value
        case "proxyjump" where host.proxyJump == nil: host.proxyJump = value
        default: break
        }
    }

    /// `Key value`, `Key=value` или `Key = "value"`.
    private static func splitKeyValue(_ line: String) -> (String, String) {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let r = line.rangeOfCharacter(from: separators) else { return (line.lowercased(), "") }
        let key = String(line[..<r.lowerBound]).lowercased()
        var value = String(line[r.upperBound...]).trimmingCharacters(in: separators)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    /// `# relaya: group=prod env=prod`
    private static func parseMeta(_ line: String) -> (group: String?, env: HostEnvironment?)? {
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard body.lowercased().hasPrefix("relaya:") else { return nil }
        var group: String?
        var env: HostEnvironment?
        for pair in body.dropFirst("relaya:".count).split(whereSeparator: \.isWhitespace) {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "group": group = kv[1]
            case "env": env = HostEnvironment(rawValue: kv[1].lowercased())
            default: break
            }
        }
        return (group, env)
    }
}
