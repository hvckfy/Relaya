import AppKit
import Observation
@preconcurrency import RoyalVNCKit
import RelayaCore

/// Встроенный VNC-клиент: соединение RoyalVNCKit, авторизация (VNC / Apple Remote Desktop)
/// с паролем из Keychain, при необходимости — через SSH-туннель.
@MainActor
@Observable
final class VNCSession: NSObject {
    enum Phase: Equatable {
        case idle, tunneling, connecting, connected
        case disconnected(String?)
    }

    /// Запрос учётных данных от сервера.
    struct CredentialRequest {
        let needsUsername: Bool
        let isAppleRemoteDesktop: Bool
        let reply: (VNCCredential?) -> Void
    }

    let desktop: RemoteDesktop
    /// Масштаб «по размеру окна»; меняется из окна с переподключением.
    private(set) var scaleToFit: Bool
    private let model: AppModel
    private let keychain = KeychainStore(service: "app.relaya.vnc-password")

    private(set) var phase: Phase = .idle
    private(set) var framebufferView: NSView?
    var credentialRequest: CredentialRequest?
    /// Почему введённый пароль не отправлен (показывается в окне ввода).
    var credentialError: String?

    @ObservationIgnored private var connection: VNCConnection?
    @ObservationIgnored private var tunnel: Tunnel?
    @ObservationIgnored private var triedSaved = false

    init(desktop: RemoteDesktop, model: AppModel) {
        self.desktop = desktop
        self.model = model
        self.scaleToFit = desktop.scaleToFit ?? true
    }

    /// Переключает масштаб: RoyalVNCKit задаёт его при подключении, поэтому переподключаемся.
    func setScaleToFit(_ fit: Bool) async {
        guard fit != scaleToFit else { return }
        scaleToFit = fit
        if let i = model.desktops.firstIndex(where: { $0.id == desktop.id }) { model.desktops[i].scaleToFit = fit }
        connection?.disconnect()
        try? await Task.sleep(for: .milliseconds(300))
        triedSaved = false
        await connect()
    }

    var account: String { desktop.keychainAccount }

    /// Сохранённый пароль; запись старого формата (без шлюза) переносится в новую один раз.
    private func savedPassword() -> String? {
        if let p = try? keychain.password(for: account) { return p }
        guard account != desktop.legacyKeychainAccount,
              let old = try? keychain.password(for: desktop.legacyKeychainAccount) else { return nil }
        try? keychain.setPassword(old, for: account)
        return old
    }

    func connect() async {
        var host = desktop.address
        var port = desktop.port
        if let t = desktop.tunnel(localPort: RemoteDesktop.freeLocalPort()) {
            phase = .tunneling
            model.tunnels.start(t, hosts: model.hosts)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if case .failed(let m) = model.tunnels.status(of: t) { phase = .disconnected(L("SSH-туннель: %@", "\(m)")); return }
                if model.tunnels.status(of: t) == .running { break }
            }
            tunnel = t
            host = "localhost"
            port = t.listenPort
        }

        phase = .connecting
        let settings = VNCConnection.Settings(isDebugLoggingEnabled: false, hostname: host, port: UInt16(port),
                                              isShared: true, isScalingEnabled: scaleToFit, useDisplayLink: true,
                                              inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
                                              isClipboardRedirectionEnabled: true, colorDepth: .depth24Bit,
                                              frameEncodings: .default)
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        self.connection = connection
        connection.connect()
    }

    func disconnect() {
        connection?.disconnect()
        if let t = tunnel { model.tunnels.stop(t.id) }
        tunnel = nil
    }

    /// Ответ из окна ввода пароля.
    func provide(username: String, password: String, save: Bool) {
        guard let request = credentialRequest else { return }
        // Пароль VNC — до 8 байт Latin-1; RoyalVNCKit 1.1.0 падает на не-ASCII символах.
        if !request.needsUsername, let problem = Self.vncPasswordProblem(password) {
            credentialError = problem
            return
        }
        credentialError = nil
        credentialRequest = nil
        if save { try? keychain.setPassword(password, for: account) }
        request.reply(request.needsUsername
            ? VNCUsernamePasswordCredential(username: username, password: password)
            : VNCPasswordCredential(password: password))
    }

    /// Почему пароль нельзя отправить как пароль VNC; nil — можно.
    static func vncPasswordProblem(_ password: String) -> String? {
        guard password.unicodeScalars.allSatisfy(\.isASCII) else {
            return L("Пароль VNC может содержать только латинские буквы, цифры и символы ASCII. Проверьте раскладку клавиатуры.")
        }
        return nil
    }

    func cancelCredentials() {
        credentialRequest?.reply(nil)
        credentialRequest = nil
    }

    // MARK: - События соединения (уже на главном потоке)

    fileprivate func stateChanged(_ status: VNCConnection.Status, error: String?) {
        switch status {
        case .connecting: phase = .connecting
        case .connected: phase = .connected
        case .disconnecting: break
        case .disconnected:
            phase = .disconnected(error)
            framebufferView = nil
            if let t = tunnel { model.tunnels.stop(t.id) }
            tunnel = nil
        @unknown default: break
        }
    }

    fileprivate func needCredential(_ type: VNCAuthenticationType, reply: @escaping (VNCCredential?) -> Void) {
        let needsUser = type.requiresUsername
        // Сначала пробуем сохранённый пароль; если сервер его отверг — спросим.
        if !triedSaved, let saved = savedPassword(), !(needsUser && desktop.user.isEmpty),
           needsUser || Self.vncPasswordProblem(saved) == nil {
            triedSaved = true
            reply(needsUser ? VNCUsernamePasswordCredential(username: desktop.user, password: saved)
                            : VNCPasswordCredential(password: saved))
            return
        }
        credentialRequest = CredentialRequest(needsUsername: needsUser,
                                              isAppleRemoteDesktop: type == .appleRemoteDesktop, reply: reply)
    }

    fileprivate func framebufferCreated(_ framebuffer: VNCFramebuffer, connection: VNCConnection) {
        let view = VNCCAFramebufferView(frame: .init(origin: .zero, size: framebuffer.cgSize),
                                        framebuffer: framebuffer, connection: connection, connectionDelegate: self)
        framebufferView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

// Колбэки RoyalVNCKit приходят с его потоков — переносим на главный.
extension VNCSession: VNCConnectionDelegate {
    nonisolated func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        let error = connectionState.error.map { "\($0.localizedDescription)" }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.stateChanged(status, error: error) } }
    }

    nonisolated func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType,
                                completion: @escaping (VNCCredential?) -> Void) {
        nonisolated(unsafe) let completion = completion
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.needCredential(authenticationType) { completion($0) } }
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        nonisolated(unsafe) let framebuffer = framebuffer
        nonisolated(unsafe) let connection = connection
        DispatchQueue.main.async { MainActor.assumeIsolated { self.framebufferCreated(framebuffer, connection: connection) } }
    }

    // Перерисовку, размер и курсор обрабатывает сам VNCCAFramebufferView.
    nonisolated func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}
    nonisolated func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                                x: UInt16, y: UInt16, width: UInt16, height: UInt16) {}
    nonisolated func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}
