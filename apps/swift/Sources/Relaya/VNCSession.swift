import AppKit
import Observation
import RelayaCore

/// Встроенный VNC на ядре (VncSession на RoyalVNCKit — тот же движок, что на Windows и Linux): кадры во вкладке,
/// вход VNC / Apple Remote Desktop / MS-Logon с паролем из Keychain, при необходимости — через SSH-туннель.
@MainActor
@Observable
final class VNCSession {
    enum Phase: Equatable {
        case idle, tunneling, connecting, connected
        case disconnected(String?)
    }

    /// Запрос учётных данных от сервера.
    struct CredentialRequest {
        let needsUsername: Bool
        let isAppleRemoteDesktop: Bool
    }

    let desktop: RemoteDesktop
    /// Масштаб «по размеру окна»; меняется из окна с переподключением.
    private(set) var scaleToFit: Bool
    private let model: AppModel
    private let keychain = KeychainStore(service: "app.relaya.vnc-password")

    private(set) var phase: Phase = .idle
    /// Холст: экран сервера и ввод (общий с RDP).
    let canvas = RDPCanvasView(frame: .zero)
    var framebufferView: NSView? { phase == .connected ? canvas : nil }
    /// Размер экрана сервера в пикселях — для режима 1:1.
    private(set) var remoteSize: CGSize = .zero
    var credentialRequest: CredentialRequest?
    /// Почему введённый пароль не отправлен (показывается в окне ввода).
    var credentialError: String?

    @ObservationIgnored private var engine: VNCEngine?
    /// Пароль, введённый в форме, — сохраняется только после успешного входа.
    @ObservationIgnored private var pendingSave: (user: String?, password: String)?
    @ObservationIgnored private var tunnel: Tunnel?
    @ObservationIgnored private var triedSaved = false
    /// V-3: причина повторного входа — показать в форме после немедленного переподключения.
    @ObservationIgnored private var retryReason: String?
    /// V-3: форму входа отменили — следующий отказ показать карточкой, без нового круга.
    @ObservationIgnored private var credentialsCancelled = false

    init(desktop: RemoteDesktop, model: AppModel) {
        self.desktop = desktop
        self.model = model
        self.scaleToFit = desktop.scaleToFit ?? true
        canvas.onRemoteSize = { [weak self] w, h in self?.remoteSize = CGSize(width: w, height: h) }
    }

    /// «По окну» или 1:1 — без переподключения: масштаб делает вид, а не сервер.
    func setScaleToFit(_ fit: Bool) async {
        guard fit != scaleToFit else { return }
        scaleToFit = fit
        if let i = model.desktops.firstIndex(where: { $0.id == desktop.id }) { model.desktops[i].scaleToFit = fit }
    }

    /// Меню окна: Ctrl+Alt+Del.
    func sendCtrlAltDel() { canvas.vncSend([0xFFE3, 0xFFE9, 0xFFFF]) }

    var account: String { desktop.keychainAccount }

    /// Сохранённый пароль; запись старого формата (без шлюза) переносится в новую один раз.
    private func savedPassword() -> String? {
        if let p = try? keychain.password(for: account) { return p }
        guard account != desktop.legacyKeychainAccount,
            let old = try? keychain.password(for: desktop.legacyKeychainAccount)
        else { return nil }
        try? keychain.setPassword(old, for: account)
        return old
    }

    /// Вкладка закрыта: запуск, который ещё ждёт (туннель, задержка перед стартом), не должен поднять соединение без вкладки.
    @ObservationIgnored private var closed = false

    func close() {
        closed = true
        disconnect()
    }

    func connect() async {
        guard !closed, engine == nil else { return }
        credentialError = retryReason
        retryReason = nil
        var host = desktop.address
        var port = desktop.port
        if let t = desktop.tunnel(localPort: RemoteDesktop.freeLocalPort()) {
            phase = .tunneling
            model.tunnels.start(t, hosts: model.hosts)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if case .failed(let m) = model.tunnels.status(of: t) { phase = .disconnected(L("SSH-туннель: %@", "\(m)")); return }
                // Туннель готов, когда ssh -L уже слушает порт: иначе FreeRDP/VNC получат отказ (TRANSPORT_FAILED).
                if model.tunnels.status(of: t) == .running, RemoteDesktop.isLocalPortListening(t.listenPort) { break }
            }
            guard model.tunnels.status(of: t) == .running, RemoteDesktop.isLocalPortListening(t.listenPort) else {
                model.tunnels.stop(t.id)
                phase = .disconnected(L("SSH-туннель не поднялся за %@ с", "10"))
                return
            }
            tunnel = t
            if closed { model.tunnels.stop(t.id); tunnel = nil; return }
            host = "127.0.0.1"
            port = t.listenPort
        }

        phase = .connecting
        triedSaved = false
        credentialsCancelled = false
        let owner = WeakVNC(self)
        var events = VNCEngine.Events()
        events.connected = { w, h in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.connected(w, h) } } }
        events.resized = { w, h in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.canvas.reset(width: w, height: h) } } }
        events.frame = { rects in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.canvas.apply(rects) } } }
        events.closed = { kind, message in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.finished(kind, message) } } }
        events.credentials = { kind, needsUser in
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.needCredential(kind, needsUser: needsUser) } }
        }
        let engine = VNCEngine(host: host, port: port, user: nil, password: nil, events: events)
        self.engine = engine
        canvas.vnc = engine
        engine.connect()
    }

    func disconnect() {
        let e = engine
        engine = nil
        canvas.releaseAll()
        canvas.vnc = nil
        e?.disconnect()
        if let t = tunnel { model.tunnels.stop(t.id) }
        tunnel = nil
        if phase == .connected || phase == .connecting { phase = .disconnected(nil) }
    }

    /// Ответ из окна ввода пароля.
    func provide(username: String, password: String, save: Bool) {
        guard let request = credentialRequest else { return }
        credentialError = nil
        credentialRequest = nil
        let user = request.needsUsername ? username : nil
        pendingSave = save ? (user, password) : nil
        engine?.provideCredentials(user: user, password: password)
    }

    func cancelCredentials() {
        credentialsCancelled = true
        credentialRequest = nil
        engine?.cancelCredentials()
    }

    // MARK: - События ядра (уже на главном потоке)

    private func connected(_ width: Int, _ height: Int) {
        canvas.reset(width: width, height: height)
        phase = .connected
        if let p = pendingSave {
            var updated = desktop
            if let u = p.user { updated.user = u }
            try? keychain.setPassword(p.password, for: updated.keychainAccount)
            if updated.user != desktop.user, let i = model.desktops.firstIndex(where: { $0.id == desktop.id }) {
                model.desktops[i].user = updated.user
            }
        }
        pendingSave = nil
        DispatchQueue.main.async { [canvas] in canvas.window?.makeFirstResponder(canvas) }
    }

    private func needCredential(_ kind: VNCEngine.AuthKind, needsUser: Bool) {
        // Mac по ARD: ⌘ уходит как Command, а не как Ctrl.
        canvas.vncCommandIsSuper = kind == .appleRemoteDesktop
        // Сначала пробуем сохранённый пароль; если сервер его отверг — спросим.
        if !triedSaved, let saved = savedPassword(), !(needsUser && desktop.user.isEmpty) {
            triedSaved = true
            engine?.provideCredentials(user: needsUser ? desktop.user : nil, password: saved)
            return
        }
        credentialRequest = CredentialRequest(needsUsername: needsUser, isAppleRemoteDesktop: kind == .appleRemoteDesktop)
    }

    private func finished(_ kind: RDPEngine.CloseKind, _ message: String) {
        guard engine != nil else { return }
        engine = nil
        canvas.vnc = nil
        credentialRequest = nil
        if let t = tunnel { model.tunnels.stop(t.id) }
        tunnel = nil
        switch kind {
        case .closedByUser: phase = .disconnected(nil)
        case .authFailed:
            pendingSave = nil
            if triedSaved {
                do { try keychain.deletePassword(for: account) } catch {
                    NSLog("Relaya VNC: пароль из Keychain не удалён: \(error.localizedDescription)")
                }
            }
            let reason = L("Неверное имя пользователя или пароль.")
            if credentialsCancelled {
                credentialError = reason
                phase = .disconnected(reason)
            } else {
                // V-3: сразу новое подключение — сервер снова спросит, а форма покажет причину.
                retryReason = reason
                Task { await connect() }
            }
        default:
            phase = .disconnected(message.isEmpty ? nil : SSHErrorText.describeRemote(.vnc, message))
        }
    }
}

/// Слабая ссылка на сессию для колбэков ядра. Читается только на главном потоке.
private final class WeakVNC: @unchecked Sendable {
    weak var value: VNCSession?
    init(_ value: VNCSession) { self.value = value }
}
