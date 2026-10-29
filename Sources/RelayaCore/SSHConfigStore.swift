import Foundation

/// Чтение и безопасная запись `~/.ssh/config`: бэкап, атомарная запись, права 600.
public struct SSHConfigStore: Sendable {
    public var url: URL

    public init(url: URL = SSHConfigParser.defaultConfigURL) {
        self.url = url
    }

    public var backupURL: URL { url.appendingPathExtension("bak") }

    public func loadDocument() throws -> SSHConfigDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return SSHConfigDocument(text: "") }
        return SSHConfigDocument(text: try String(contentsOf: url, encoding: .utf8))
    }

    public func save(_ document: SSHConfigDocument) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if fm.fileExists(atPath: url.path) {
            if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
            try fm.copyItem(at: url, to: backupURL)
        }
        try Data(document.text.utf8).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
