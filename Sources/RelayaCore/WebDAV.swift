import Foundation

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

    /// Пошаговый разбор: копит байты, отдаёт готовые запросы (Content-Length и chunked).
    public struct Parser: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func feed(_ data: Data) -> [Request] {
            buffer.append(data)
            var out: [Request] = []
            while let r = next() { out.append(r) }
            return out
        }

        private mutating func next() -> Request? {
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { buffer.removeAll(); return nil }
            var headers: [String: String] = [:]
            for l in lines {
                guard let c = l.firstIndex(of: ":") else { continue }
                headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyStart = headEnd.upperBound
            var body = Data()
            var consumed: Data.Index
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                guard let (decoded, end) = Self.dechunk(buffer, from: bodyStart) else { return nil }
                body = decoded
                consumed = end
            } else {
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
                consumed = buffer.index(bodyStart, offsetBy: length)
                body = buffer[bodyStart..<consumed]
            }
            buffer = Data(buffer[consumed...])
            let rawPath = String(first[1]).components(separatedBy: "?")[0]
            return Request(method: String(first[0]).uppercased(), path: rawPath.removingPercentEncoding ?? rawPath,
                           headers: headers, body: Data(body))
        }

        /// Тело chunked; nil — пришло не целиком.
        static func dechunk(_ data: Data, from start: Data.Index) -> (Data, Data.Index)? {
            var out = Data()
            var i = start
            while true {
                guard let lineEnd = data[i...].range(of: Data("\r\n".utf8)) else { return nil }
                let sizeLine = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
                guard let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16) else { return nil }
                let chunkStart = lineEnd.upperBound
                guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
                if size == 0 {
                    // Возможные trailer-заголовки до пустой строки.
                    guard let end = data[chunkStart...].range(of: Data("\r\n".utf8)) else { return nil }
                    return (out, end.upperBound)
                }
                let chunkEnd = data.index(chunkStart, offsetBy: size)
                out.append(data[chunkStart..<chunkEnd])
                i = data.index(chunkEnd, offsetBy: 2)
            }
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
        var xml = #"<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">"#
        for e in entries {
            xml += "<D:response><D:href>\(escape(encodePath(e.href)))</D:href><D:propstat><D:prop>"
            xml += "<D:displayname>\(escape(e.name))</D:displayname>"
            xml += "<D:getlastmodified>\(httpDate(e.modified))</D:getlastmodified>"
            xml += "<D:creationdate>\(iso8601(e.modified))</D:creationdate>"
            if e.isDirectory {
                xml += "<D:resourcetype><D:collection/></D:resourcetype>"
            } else {
                xml += "<D:resourcetype/><D:getcontentlength>\(e.size)</D:getcontentlength>"
                xml += "<D:getcontenttype>application/octet-stream</D:getcontenttype>"
            }
            xml += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
            xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }
        xml += "</D:multistatus>"
        return Data(xml.utf8)
    }

    /// Ответ на LOCK: Finder без него подключает диск только для чтения. Блокировка условная.
    public static func lockResponse(token: String, path: String) -> Data {
        Data(("""
        <?xml version="1.0" encoding="utf-8"?><D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>\
        <D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>\
        <D:timeout>Second-3600</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken>\
        <D:lockroot><D:href>\(escape(encodePath(path)))</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>
        """).utf8)
    }

    public static func response(_ status: Int, _ reason: String, headers: [String: String] = [:], body: Data = Data()) -> Data {
        var h = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["DAV"] = "1, 2"
        all["MS-Author-Via"] = "DAV"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        return Data(h.utf8) + body
    }

    /// Путь из заголовка Destination (`http://127.0.0.1:port/a/b`) → `/a/b`.
    public static func destinationPath(_ header: String?) -> String? {
        guard let header else { return nil }
        let path = URL(string: header)?.path(percentEncoded: false) ?? header
        return path.isEmpty ? "/" : path
    }

    /// Служебные файлы Finder (`._*`, `.DS_Store`): на сервер их не пишем.
    public static func isFinderJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name == ".localized" || name == ".hidden"
    }

    static func encodePath(_ p: String) -> String {
        p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? p
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func httpDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: d)
    }

    static func iso8601(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// Дата из `ls -la` sftp: `Oct 29 12:00` (текущий год) или `Oct 29  2024`.
    public static func date(fromListing s: String, now: Date = Date()) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let parts = s.split(separator: " ").map(String.init)
        guard parts.count == 3 else { return now }
        if parts[2].contains(":") {
            let year = Calendar(identifier: .gregorian).component(.year, from: now)
            f.dateFormat = "MMM d HH:mm yyyy"
            guard let d = f.date(from: "\(parts[0]) \(parts[1]) \(parts[2]) \(year)") else { return now }
            return d > now.addingTimeInterval(86400) ? Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: d) ?? d : d
        }
        f.dateFormat = "MMM d yyyy"
        return f.date(from: s.replacingOccurrences(of: "  ", with: " ")) ?? now
    }
}
