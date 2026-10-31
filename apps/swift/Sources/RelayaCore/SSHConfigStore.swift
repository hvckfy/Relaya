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

    /// Записать конфиг: копия в config.bak (если `backup`), затем временный файл с правами 600 и атомарная замена —
    /// окна, когда конфиг доступен другим (0644), нет.
    /// Фоновые правки одних метаданных (`backup: false`) не затирают копию, сделанную перед правкой пользователя.
    public func save(_ document: SSHConfigDocument, backup: Bool = true) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if backup, fm.fileExists(atPath: url.path) {
            if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
            try fm.copyItem(at: url, to: backupURL)
        }
        let tmp = dir.appending(path: ".config.relaya-\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: tmp.path, contents: Data(document.text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
