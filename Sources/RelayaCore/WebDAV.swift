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
        davMultistatus(entries: entries.map {
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
}
