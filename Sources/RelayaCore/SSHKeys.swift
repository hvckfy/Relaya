import Foundation

/// Пара ключей из ~/.ssh (приватный файл + `.pub` рядом).
public struct SSHKey: Identifiable, Hashable, Sendable {
    public var id: String { path }

    public var name: String
    /// Абсолютный путь к приватному ключу.
    public var path: String
    public var type: String
    public var bits: Int?
    public var fingerprint: String
    public var comment: String
    public var publicKey: String
    public var hasPassphrase: Bool
    public var created: Date?

    /// Путь в виде `~/.ssh/name`, как его пишут в config.
    public var displayPath: String { SSHPaths.abbreviate(path) }
}

public enum SSHPaths {
    public static var sshDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
    }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Строка `ssh-keygen -lf`: `256 SHA256:abc… comment (ED25519)`.
public struct KeyFingerprint: Equatable, Sendable {
    public var bits: Int?
    public var fingerprint: String
    public var comment: String
    public var type: String

    public static func parse(_ line: String) -> KeyFingerprint? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard parts.count >= 3, parts[1].contains(":"),
              let last = parts.last, last.hasPrefix("("), last.hasSuffix(")") else { return nil }
        let comment = parts.count > 3 ? parts[2..<(parts.count - 1)].joined(separator: " ") : ""
        return KeyFingerprint(bits: Int(parts[0]), fingerprint: parts[1], comment: comment,
                              type: String(last.dropFirst().dropLast()).lowercased())
    }
}

public enum KeyScanner {
    /// Все пары ключей в ~/.ssh, отсортированные по имени.
    public static func scan(directory: URL = SSHPaths.sshDirectory) async -> [SSHKey] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        var keys: [SSHKey] = []
        for name in names.sorted() where names.contains(name + ".pub") {
            let path = directory.appending(path: name).path
            if let key = await inspect(path: path) { keys.append(key) }
        }
        return keys
    }

    public static func inspect(path: String) async -> SSHKey? {
        let pubPath = path + ".pub"
        guard let pub = try? String(contentsOfFile: pubPath, encoding: .utf8),
              let result = try? await ProcessRunner.run("/usr/bin/ssh-keygen", ["-lf", pubPath]),
              result.succeeded, let fp = KeyFingerprint.parse(result.stdout) else { return nil }
        // Пустая passphrase подходит → ключ без защиты. Секрет ни во что не передаём.
        let probe = try? await ProcessRunner.run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", path])
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return SSHKey(
            name: (path as NSString).lastPathComponent,
            path: path,
            type: fp.type,
            bits: fp.bits,
            fingerprint: fp.fingerprint,
            comment: fp.comment,
            publicKey: pub.trimmingCharacters(in: .whitespacesAndNewlines),
            hasPassphrase: probe?.succeeded != true,
            created: attrs?[.creationDate] as? Date
        )
    }

    /// Отпечатки ключей, загруженных в ssh-agent.
    public static func agentFingerprints() async -> Set<String> {
        guard let r = try? await ProcessRunner.run("/usr/bin/ssh-add", ["-l"]), r.succeeded else { return [] }
        return Set(r.stdout.split(separator: "\n").compactMap { KeyFingerprint.parse(String($0))?.fingerprint })
    }
}
