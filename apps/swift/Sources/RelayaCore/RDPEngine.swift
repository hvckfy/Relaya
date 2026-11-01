import Foundation
import RelayaRust

/// Узел RDP, чей сертификат проверяется (R-4): адрес, порт, роль — шлюз, сервер, перенаправление.
public typealias CertNode = RelayaRust.CertNode
public typealias CertRole = RelayaRust.CertRole
// Запись ядра из строки, порта и перечисления — значение без ссылок, безопасно передавать между потоками
// (колбэк ядра → главный поток).
extension RelayaRust.CertNode: @retroactive @unchecked Sendable {}
extension RelayaRust.CertRole: @retroactive @unchecked Sendable {}

/// Встроенный RDP ядра (FreeRDP 3): Swift-фасад над `RemoteSession`. Колбэки приходят с потока сессии ядра —
/// перенос в главный поток делает вызывающий.
public final class RDPEngine: @unchecked Sendable {
    public struct Config: Sendable {
        public var host: String
        public var port: Int
        public var user: String
        public var password: String
        public var domain: String?
        public var width: Int
        public var height: Int
        /// Масштаб рабочего стола на сервере, 100 — без масштаба.
        public var scalePercent: Int
        /// SHA-256 сертификата, которому пользователь уже доверился (сервер из настроек).
        public var trustedCertificate: String?
        /// Доверие по узлам (R-4): `host:port` → SHA-256 — шлюз и серверы после перенаправления.
        public var trustedNodes: [String: String] = [:]
        /// RD Gateway; nil — напрямую. Пустые учётные данные шлюза — те же, что для сервера.
        public var gatewayHost: String?
        public var gatewayUser: String?
        public var gatewayPassword: String?
        public var gatewayDomain: String?
        /// Проверенная библиотека OpenH264 (OpenH264.libraryPath); nil — без H.264.
        public var h264LibraryPath: String?

        public init(host: String, port: Int, user: String, password: String, domain: String?,
                    width: Int, height: Int, scalePercent: Int, trustedCertificate: String?,
                    trustedNodes: [String: String] = [:],
                    gatewayHost: String? = nil, gatewayUser: String? = nil, gatewayPassword: String? = nil,
                    gatewayDomain: String? = nil, h264LibraryPath: String? = nil) {
            self.host = host; self.port = port; self.user = user; self.password = password; self.domain = domain
            self.width = width; self.height = height; self.scalePercent = scalePercent
            self.trustedCertificate = trustedCertificate
            self.trustedNodes = trustedNodes
            self.gatewayHost = gatewayHost; self.gatewayUser = gatewayUser
            self.gatewayPassword = gatewayPassword; self.gatewayDomain = gatewayDomain
            self.h264LibraryPath = h264LibraryPath
        }
    }

    /// Изменившийся прямоугольник, пиксели BGRA построчно без отступов.
    public struct Rect: Sendable {
        public let x: Int, y: Int, width: Int, height: Int
        public let bgra: Data
    }

    /// `credentialsRequired` — сервер требует логин и пароль (форма входа); `accountProblem` — учётная запись не пускает,
    /// сохранённый пароль не стирать (R-2, R-3).
    public enum CloseKind: Sendable {
        case authFailed, network, serverClosed, certRejected, protocolError, closedByUser, credentialsRequired, accountProblem
    }

    public struct AudioFormat: Sendable, Equatable {
        public let sampleRate: Int, channels: Int, bitsPerSample: Int
    }

    public struct Events: Sendable {
        public var connected: @Sendable (Int, Int) -> Void = { _, _ in }
        public var frame: @Sendable ([Rect]) -> Void = { _ in }
        public var resized: @Sendable (Int, Int) -> Void = { _, _ in }
        /// Сертификат не тот, которому доверились: ответ — `acceptCertificate`. Без ответа — отказ.
        public var certificate: @Sendable (_ sha256: String, _ subject: String, _ node: CertNode) -> Void = { _, _, _ in }
        public var closed: @Sendable (CloseKind, String) -> Void = { _, _ in }
        public var clipboard: @Sendable (String) -> Void = { _ in }
        public var audio: @Sendable (AudioFormat, Data) -> Void = { _, _ in }
        public var audioVolume: @Sendable (Double) -> Void = { _ in }
        public init() {}
    }

    private let session: RemoteSession
    private let listener: Listener

    public init(config c: Config, events: Events) {
        listener = Listener(events)
        session = RemoteSession.rdp(
            config: RdpConfig(host: c.host, port: UInt16(clamping: c.port), user: c.user, password: c.password, domain: c.domain,
                              width: UInt16(clamping: c.width), height: UInt16(clamping: c.height),
                              scalePercent: UInt32(clamping: c.scalePercent), trustedCertSha256: c.trustedCertificate,
                              trustedCerts: c.trustedNodes.compactMap { key, sha in
                                  guard let i = key.lastIndex(of: ":"), let port = UInt16(key[key.index(after: i)...]) else { return nil }
                                  return TrustedCert(host: String(key[..<i]), port: port, sha256: sha)
                              },
                              gatewayHost: c.gatewayHost, gatewayUser: c.gatewayUser, gatewayPassword: c.gatewayPassword,
                              gatewayDomain: c.gatewayDomain,
                              h264LibraryPath: c.h264LibraryPath),
            listener: listener)
        // Звук и буфер обмена — до connect: иначе сервер не предложит каналы.
        session.setClipboardListener(listener: listener)
        session.setAudioListener(listener: listener)
    }

    public func connect() { session.connect() }
    public func disconnect() { session.disconnect() }
    public func acceptCertificate(_ accept: Bool) { session.acceptCert(accept: accept) }
    /// Scancode набора 1; расширенные — с префиксом 0xE0 (0xE04B — стрелка влево).
    public func key(_ scancode: UInt16, down: Bool) { session.key(scancode: scancode, down: down) }
    public func unicode(_ scalar: UInt32, down: Bool) { session.unicode(codepoint: scalar, down: down) }
    public func pointer(x: Int, y: Int) { session.pointer(x: UInt16(clamping: x), y: UInt16(clamping: y)) }
    /// 0 — левая, 1 — средняя, 2 — правая, 3 и 4 — «назад» и «вперёд».
    public func button(_ button: Int, down: Bool) { session.button(button: UInt8(clamping: button), down: down) }
    /// `units` — как WHEEL_DELTA (120 на щелчок), положительное — вверх/вправо.
    public func wheel(_ units: Int, vertical: Bool) { session.wheel(units: Int16(clamping: units), vertical: vertical) }
    public func resize(width: Int, height: Int) { session.resize(width: UInt16(clamping: width), height: UInt16(clamping: height)) }
    public func setClipboard(_ text: String) { session.setClipboard(text: text) }

    private final class Listener: RemoteListener, RemoteClipboardListener, RemoteAudioListener, @unchecked Sendable {
        let events: Events
        init(_ events: Events) { self.events = events }

        func onConnected(width: UInt16, height: UInt16) { events.connected(Int(width), Int(height)) }
        func onFrame(rects: [FrameRect]) {
            events.frame(rects.map { Rect(x: Int($0.x), y: Int($0.y), width: Int($0.width), height: Int($0.height), bgra: $0.bgra) })
        }
        func onResize(width: UInt16, height: UInt16) { events.resized(Int(width), Int(height)) }
        func onCert(sha256: String, subject: String, node: CertNode) { events.certificate(sha256, subject, node) }
        func onClosed(close: RemoteClose) {
            let kind: CloseKind = switch close.kind {
            case .authFailed: .authFailed
            case .network: .network
            case .serverClosed: .serverClosed
            case .certRejected: .certRejected
            case .protocol: .protocolError
            case .closedByUser: .closedByUser
            case .credentialsRequired: .credentialsRequired
            case .accountProblem: .accountProblem
            }
            events.closed(kind, close.message)
        }
        func onRemoteClipboard(text: String) { events.clipboard(text) }
        func onAudio(format: RelayaRust.AudioFormat, timestamp: UInt32, pcm: Data) {
            events.audio(AudioFormat(sampleRate: Int(format.sampleRate), channels: Int(format.channels),
                                     bitsPerSample: Int(format.bitsPerSample)), pcm)
        }
        func onAudioVolume(left: UInt16, right: UInt16) { events.audioVolume(Double(max(left, right)) / 65535) }
        func onAudioClosed() {}
    }
}
