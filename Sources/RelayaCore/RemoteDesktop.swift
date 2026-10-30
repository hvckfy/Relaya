import Foundation

/// Подключение к удалённому рабочему столу (VNC или RDP).
///
/// Экран рисует системный клиент: VNC — встроенный в macOS «Общий экран» (Screen Sharing),
/// RDP — приложение Microsoft «Windows App». Relaya хранит подключения, при необходимости
/// поднимает SSH-туннель и открывает клиент с нужным адресом.
public struct RemoteDesktop: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case vnc, rdp

        public var title: String { rawValue.uppercased() }
        public var defaultPort: Int { self == .vnc ? 5900 : 3389 }
    }

    public var id = UUID()
    public var name: String
    public var kind: Kind
    public var address: String
    public var port: Int
    public var user: String
    /// Если задан — подключаемся через SSH-туннель к этому хосту из ~/.ssh/config,
    /// а `address` считается адресом с точки зрения сервера (обычно localhost).
    public var viaSSHHost: String?
    /// Только для RDP.
    public var fullScreen: Bool
    /// VNC: вписывать экран в окно (nil или true) или показывать 1:1 с прокруткой.
    /// Optional — чтобы старые desktops.json без этого поля читались.
    public var scaleToFit: Bool?
    /// RDP: фиксированное разрешение рабочего стола; nil — по размеру окна (подстраивается на лету).
    public var rdpWidth: Int?
    public var rdpHeight: Int?
    /// RDP: масштаб интерфейса Windows как на Retina (nil или true) или 100% — мельче, но больше места.
    public var rdpRetina: Bool?

    /// Готовые разрешения для меню.
    public static let rdpResolutionPresets: [(Int, Int)] = [(1280, 720), (1440, 900), (1920, 1080), (2560, 1440), (3840, 2160)]

    public init(name: String, kind: Kind, address: String, port: Int? = nil, user: String = "",
                viaSSHHost: String? = nil, fullScreen: Bool = false) {
        self.name = name
        self.kind = kind
        self.address = address
        self.port = port ?? kind.defaultPort
        self.user = user
        self.viaSSHHost = viaSSHHost
        self.fullScreen = fullScreen
    }

    public var validationError: String? {
        if address.trimmingCharacters(in: .whitespaces).isEmpty { return L("Укажите адрес") }
        if !(1...65535).contains(port) { return L("Порт — число от 1 до 65535") }
        return nil
    }

    public var summary: String {
        let target = "\(user.isEmpty ? "" : user + "@")\(address):\(port)"
        return viaSSHHost.map { L("%@ через SSH %@", "\(target)", "\($0)") } ?? target
    }

    /// Туннель для подключения через SSH: локальный порт → address:port на сервере.
    public func tunnel(localPort: Int) -> Tunnel? {
        guard let via = viaSSHHost, !via.isEmpty else { return nil }
        return Tunnel(name: "\(kind.title) \(name)", hostAlias: via, kind: .local,
                      listenPort: localPort, targetHost: address, targetPort: port)
    }

    /// `vnc://user@host:port` для «Общего экрана».
    public func vncURL(host: String, port: Int) -> URL? {
        var c = URLComponents()
        c.scheme = "vnc"
        c.host = host
        c.port = port
        if !user.isEmpty { c.user = user }
        return c.url
    }

    /// Содержимое .rdp-файла для Windows App / Remote Desktop.
    public func rdpFile(host: String, port: Int) -> String {
        var lines = [
            "full address:s:\(host):\(port)",
            "screen mode id:i:\(fullScreen ? 2 : 1)",
            "prompt for credentials:i:1",
            "redirectclipboard:i:1",
            "audiomode:i:0",
            "use multimon:i:0",
            "dynamic resolution:i:1",
        ]
        if !user.isEmpty { lines.append("username:s:\(user)") }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Свободен ли порт на localhost.
    public static func isLocalPortFree(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Локальный порт для проброса: тот же номер, что на сервере, если свободен; иначе 10000+номер; иначе любой.
    public static func preferredLocalPort(for remotePort: Int) -> Int {
        for candidate in [remotePort, 10000 + remotePort, 20000 + remotePort] where candidate > 1023 && isLocalPortFree(candidate) {
            return candidate
        }
        return freeLocalPort()
    }

    /// Свободный локальный порт для туннеля.
    public static func freeLocalPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : 0
    }
}

public struct RemoteDesktopStore: Sendable {
    public var url: URL

    public init(url: URL = RemoteDesktopStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        RelayaPaths.supportDirectory.appending(path: "desktops.json")
    }

    public func load() -> [RemoteDesktop] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RemoteDesktop].self, from: data)) ?? []
    }

    public func save(_ items: [RemoteDesktop]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: url, options: .atomic)
    }
}
