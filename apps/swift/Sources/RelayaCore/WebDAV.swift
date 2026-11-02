import Foundation
import RelayaRust

/// Минимальный HTTP/1.1 + WebDAV (класс 1–2) для моста «SFTP → диск в Finder».
/// Finder подключает WebDAV сам, без расширений ядра и без аккаунта разработчика.
public enum WebDAV {
    public struct Request: Equatable, Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
        public var body: Data

        public func header(_ name: String) -> String? { headers[name.lowercased()] }
        /// `Depth: 0` — только сам ресурс, иначе — с детьми (Finder шлёт 1).
        public var depth: Int { header("depth") == "0" ? 0 : 1 }
    }

    // Логика — в Rust-ядре (`core/src/webdav.rs`).

    /// Пошаговый разбор: копит байты, отдаёт готовые запросы (Content-Length и chunked).
    public struct Parser: @unchecked Sendable {
        private let parser = DavParser()
        public init() {}

        public mutating func feed(_ data: Data) -> [Request] {
            parser.feed(data: data).map { Request(method: $0.method, path: $0.path, headers: $0.headers, body: $0.body) }
        }
    }

    /// Свойства ресурса для PROPFIND.
    public struct Entry: Sendable {
        public var href: String
        public var name: String
        public var isDirectory: Bool
        public var size: Int64
        public var modified: Date

        public init(href: String, name: String, isDirectory: Bool, size: Int64, modified: Date) {
            self.href = href
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.modified = modified
        }
    }

    public static func multistatus(_ entries: [Entry]) -> Data {
        davMultistatus(
            entries: entries.map {
                DavEntry(href: $0.href, name: $0.name, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified.timeIntervalSince1970)
            })
    }

    /// Ответ на LOCK: Finder без него подключает диск только для чтения. Блокировка условная.
    public static func lockResponse(token: String, path: String) -> Data { davLockResponse(token: token, path: path) }

    public static func response(_ status: Int, _ reason: String, headers: [String: String] = [:], body: Data = Data()) -> Data {
        davResponse(status: UInt16(status), reason: reason, headers: headers, body: body)
    }

    /// Путь из заголовка Destination (`http://127.0.0.1:port/a/b`) → `/a/b`.
    public static func destinationPath(_ header: String?) -> String? { davDestinationPath(header: header) }

    /// Служебные файлы Finder (`._*`, `.DS_Store`): на сервер их не пишем.
    public static func isFinderJunk(_ name: String) -> Bool { davIsFinderJunk(name: name) }

    /// Дата из `ls -la` sftp: `Oct 29 12:00` (текущий год) или `Oct 29  2024`.
    public static func date(fromListing s: String, now: Date = Date()) -> Date {
        Date(timeIntervalSince1970: davDateFromListing(s: s, now: now.timeIntervalSince1970))
    }

    // Правила моста — в ядре (`core/src/webdav_policy.rs`): клиент только выполняет решение.

    public typealias Secrets = DavSecrets
    public typealias Action = DavAction
    public typealias TransferPlan = DavTransferPlan

    /// Случайные путь `/<uuid>/<имя>` и Basic-пароль одного подключения диска.
    public static func newSecrets(volumeName: String) -> Secrets { davNewSecrets(volumeName: volumeName) }

    /// Заголовок `Authorization` совпадает с паролем подключения (сравнение за постоянное время).
    public static func isAuthorized(_ authorization: String?, password: String) -> Bool {
        davAuthorized(authorization: authorization, password: password)
    }

    /// Имя диска в Finder: хост, для вложенной папки — «хост · папка».
    public static func volumeName(alias: String, path: String) -> String { davVolumeName(alias: alias, path: path) }

    public static func rootNeedsHome(_ requested: String) -> Bool { davRootNeedsHome(requested: requested) }

    /// Корень диска на сервере; `.`/`..` — ошибка.
    public static func resolveRoot(_ requested: String, home: String) throws -> String {
        try davResolveRoot(requested: requested, home: home)
    }

    /// Что сделать по запросу и каким кодом ответить (после проверки пароля).
    public static func decide(_ req: Request, prefix: String, root: String) -> Action {
        davDecide(
            method: req.method, path: req.path, destination: req.header("destination"),
            overwrite: req.header("overwrite"), prefix: prefix, root: root)
    }

    public static func transferPlan(
        source: String, destination: String, isMove: Bool, overwrite: Bool,
        destinationExists: Bool
    ) -> TransferPlan {
        davTransferPlan(
            source: source, destination: destination, isMove: isMove, overwrite: overwrite,
            destinationExists: destinationExists)
    }

    public static func deleteCommand(_ remote: String) -> String { davDeleteCommand(remote: remote) }
    public static func existsCommand(_ remote: String) -> String { davExistsCommand(remote: remote) }

    /// Временный файл для GET/PUT в приватном (0700) каталоге процесса.
    public static func tempFile() throws -> URL { URL(fileURLWithPath: try davTempFile()) }

    /// Удалить каталог временных файлов процесса — при выходе из приложения.
    public static func tempCleanup() throws { try davTempCleanup() }
}
