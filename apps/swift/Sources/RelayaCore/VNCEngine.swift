import Foundation
import RelayaRust

/// Встроенный VNC ядра (RoyalVNCKit через C API, feature vnc-royal) — тот же движок, что на Windows и Linux.
/// Колбэки приходят с потоков RoyalVNC; перенос в главный поток делает вызывающий.
public final class VNCEngine: @unchecked Sendable {
    public enum AuthKind: Sendable { case vnc, appleRemoteDesktop, msLogon }

    public struct Events: Sendable {
        public var connected: @Sendable (Int, Int) -> Void = { _, _ in }
        public var frame: @Sendable ([RDPEngine.Rect]) -> Void = { _ in }
        public var resized: @Sendable (Int, Int) -> Void = { _, _ in }
        public var closed: @Sendable (RDPEngine.CloseKind, String) -> Void = { _, _ in }
        /// Сервер просит вход: ответ — `provideCredentials` или `cancelCredentials`.
        public var credentials: @Sendable (AuthKind, _ needsUser: Bool) -> Void = { _, _ in }
        public init() {}
    }

    private let session: VncSession
    private let listener: Listener

    public init(host: String, port: Int, user: String?, password: String?, events: Events) {
        listener = Listener(events)
        session = VncSession.vnc(config: VncConfig(host: host, port: UInt16(clamping: port), user: user,
                                                   password: password, shared: true),
                                 listener: listener)
        session.setAuthListener(listener: listener)
    }

    public func connect() { session.connect() }
    public func disconnect() { session.disconnect() }
    public func provideCredentials(user: String?, password: String) { session.provideCredentials(user: user, password: password) }
    public func cancelCredentials() { session.cancelCredentials() }
    /// Keysym X11 (0xff0d — Return, 0xffe1 — Shift и т. п.).
    public func key(_ keysym: UInt32, down: Bool) { session.key(keysym: keysym, down: down) }
    public func pointer(x: Int, y: Int) { session.pointer(x: UInt16(clamping: x), y: UInt16(clamping: y)) }
    public func button(_ button: Int, down: Bool) { session.button(button: UInt8(clamping: button), down: down) }
    public func wheel(_ units: Int, vertical: Bool) { session.wheel(units: Int16(clamping: units), vertical: vertical) }

    /// Keysym символа (латиница как есть, остальное — 0x0100_0000 + код), правило ядра.
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32 { vncKeysymForChar(codepoint: scalar.value) }

    private final class Listener: RemoteListener, VncAuthListener, @unchecked Sendable {
        let events: Events
        init(_ events: Events) { self.events = events }

        func onConnected(width: UInt16, height: UInt16) { events.connected(Int(width), Int(height)) }
        func onFrame(rects: [FrameRect]) {
            events.frame(rects.map { RDPEngine.Rect(x: Int($0.x), y: Int($0.y), width: Int($0.width), height: Int($0.height), bgra: $0.bgra) })
        }
        func onResize(width: UInt16, height: UInt16) { events.resized(Int(width), Int(height)) }
        func onCert(sha256: String, subject: String) {}
        func onClosed(close: RemoteClose) {
            let kind: RDPEngine.CloseKind = switch close.kind {
            case .authFailed: .authFailed
            case .network: .network
            case .serverClosed: .serverClosed
            case .certRejected: .certRejected
            case .protocol: .protocolError
            case .closedByUser: .closedByUser
            }
            events.closed(kind, close.message)
        }
        func onCredentials(kind: VncAuthKind, needsUser: Bool) {
            let k: AuthKind = switch kind {
            case .vnc: .vnc
            case .appleRemoteDesktop: .appleRemoteDesktop
            case .msLogon: .msLogon
            }
            events.credentials(k, needsUser)
        }
    }
}
