import AppKit
import Observation
import RelayaCore

/// Встроенный RDP на FreeRDP ядра (тот же движок, что на Windows и Linux): кадры BGRA во вкладке, клавиатура,
/// мышь, звук, общий буфер обмена, смена разрешения на лету. Пароль — из Keychain или из окна ввода,
/// сертификат сервера — доверие при первом подключении, смена отпечатка — предупреждение.
@MainActor
@Observable
final class RDPSession {
    enum Phase: Equatable {
        case idle, tunneling, needsCredentials, connecting, connected
        case disconnected(String?)
    }

    let desktop: RemoteDesktop
    private let model: AppModel
    private let keychain = KeychainStore(service: "app.relaya.rdp-password")

    private(set) var phase: Phase = .idle
    /// Отпечаток сертификата сервера (SHA-256), которому доверились.
    private(set) var certificate: String?
    /// Подключение оборвано из-за смены сертификата сервера.
    private(set) var certificateMismatch = false
    /// Отпечаток ждёт решения пользователя (alert в окне); `changed` — раньше доверяли другому.
    private(set) var trustPrompt: String?
    private(set) var trustPromptChanged = false

    /// Ответ на «доверять сертификату?»: ядро ждёт его до отправки учётных данных.
    func answerTrust(_ trust: Bool) {
        if trust, let fp = trustPrompt {
            UserDefaults.standard.set(fp, forKey: certificateKey)
            certificate = fp
        }
        if !trust, trustPromptChanged { certificateMismatch = true }
        trustPrompt = nil
        engine?.acceptCertificate(trust)
    }
    /// Фиксированное разрешение (nil — по размеру окна) и масштаб; меняются на лету из меню окна.
    private(set) var fixedSize: (width: Int, height: Int)?
    private(set) var retina: Bool
    /// FreeRDP меняет разрешение через канал disp без переподключения.
    var canResize: Bool { phase == .connected }
    @ObservationIgnored private var surface: (points: CGSize, scale: CGFloat)?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var lastSize: (Int, Int)?
    /// Холст: экран удалённой машины и ввод.
    let canvas = RDPCanvasView(frame: .zero)
    @ObservationIgnored private let audio = RDPAudio()
    @ObservationIgnored private var pendingSave: (password: String, account: String)?

    // Е.18: звук и общий буфер обмена по столу — как desktop.<id>.volume / .clipboard на Windows и Linux.
    private var volumeKey: String { "desktop.\(desktop.id.uuidString).volume" }
    private var clipboardKey: String { "desktop.\(desktop.id.uuidString).clipboard" }

    /// Громкость 0…100.
    var volume: Double = 100 {
        didSet {
            UserDefaults.standard.set(volume, forKey: volumeKey)
            audio.setUserVolume(volume / 100)
        }
    }

    /// Общий буфер обмена с сервером; выключение очищает отправленный текст на сервере (как W-RDP-2).
    var clipboardEnabled = true {
        didSet {
            UserDefaults.standard.set(clipboardEnabled, forKey: clipboardKey)
            if !clipboardEnabled { engine?.setClipboard("") } else { lastPasteboard = -1; sendLocalClipboard() }
        }
    }
    @ObservationIgnored private var engine: RDPEngine?
    @ObservationIgnored private var tunnel: Tunnel?
    @ObservationIgnored private var target: (host: String, port: Int) = ("", 0)
    @ObservationIgnored private var lastPasteboard = NSPasteboard.general.changeCount

    init(desktop: RemoteDesktop, model: AppModel) {
        self.desktop = desktop
        self.model = model
        if let w = desktop.rdpWidth, let h = desktop.rdpHeight { fixedSize = (w, h) }
        retina = desktop.rdpRetina ?? true
        volume = UserDefaults.standard.object(forKey: "desktop.\(desktop.id.uuidString).volume") as? Double ?? 100
        clipboardEnabled = UserDefaults.standard.object(forKey: "desktop.\(desktop.id.uuidString).clipboard") as? Bool ?? true
        audio.setUserVolume(volume / 100)  // в init didSet не срабатывает
        canvas.onSurfaceChange = { [weak self] points, scale in self?.surfaceChanged(points: points, scale: scale) }
        canvas.onFocus = { [weak self] in self?.sendLocalClipboard() }
    }

    // MARK: - Разрешение

    /// Размер рабочего стола в пикселях: фиксированный или по окну (Retina — в пикселях экрана, 100% — в точках).
    private func desiredSize(points: CGSize, scale: CGFloat) -> (Int, Int) {
        if let fixedSize { return (min(8192, max(640, fixedSize.width)), min(8192, max(480, fixedSize.height))) }
        let k = retina ? scale : 1
        // Чётная ширина — требование RDP к размеру рабочего стола.
        let w = Int((points.width * k).rounded()) & ~1, h = Int((points.height * k).rounded())
        return (min(8192, max(640, w)), min(8192, max(480, h)))
    }

    private var scalePercent: Int { retina ? Int(((surface?.scale ?? 2) * 100).rounded()) : 100 }

    private func surfaceChanged(points: CGSize, scale: CGFloat) {
        surface = (points, scale)
        guard fixedSize == nil else { return }
        scheduleResize()
    }

    /// Окно перестали тянуть — через полсекунды просим сервер перестроить рабочий стол.
    private func scheduleResize(delay: Duration = .milliseconds(500)) {
        guard phase == .connected, let surface else { return }
        let size = desiredSize(points: surface.points, scale: surface.scale)
        guard lastSize.map({ $0 != size }) ?? true else { return }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let engine = self.engine else { return }
            engine.resize(width: size.0, height: size.1)
            self.lastSize = size
        }
    }

    /// Меню «Разрешение»: фиксированное значение или nil — по размеру окна.
    func setResolution(_ size: (width: Int, height: Int)?) {
        fixedSize = size
        persist { $0.rdpWidth = size?.width; $0.rdpHeight = size?.height }
        scheduleResize(delay: .zero)
    }

    func setRetina(_ on: Bool) {
        retina = on
        persist { $0.rdpRetina = on }
        scheduleResize(delay: .zero)
    }

    private func persist(_ change: (inout RemoteDesktop) -> Void) {
        if let i = model.desktops.firstIndex(where: { $0.id == desktop.id }) { change(&model.desktops[i]) }
    }

    /// Во весь экран и обратно (кнопка панели, чек-лист 9.11).
    func toggleFullScreen() { canvas.window?.toggleFullScreen(nil) }

    /// Меню окна: сочетания, которые Mac не отдаёт приложению.
    func sendCtrlAltDel() { canvas.send(RDPCanvasView.ctrlAltDel) }
    func sendWindowsKey() { canvas.send(RDPCanvasView.windowsKey) }
    func sendAltTab() { canvas.send(RDPCanvasView.altTab) }

    // MARK: - Буфер обмена

    /// Локальный буфер уходит на сервер, только когда вкладка в фокусе (W-RDP-1): копирование для других целей
    /// не рассылается на все открытые столы.
    private func sendLocalClipboard() {
        guard clipboardEnabled else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboard, let text = pb.string(forType: .string) else { return }
        lastPasteboard = pb.changeCount
        engine?.setClipboard(text)
    }

    private func remoteClipboard(_ text: String) {
        guard clipboardEnabled else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastPasteboard = pb.changeCount
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
    private var certificateKey: String {
        "rdp.certificate.\(desktop.address):\(desktop.port)" + (desktop.viaSSHHost.flatMap { $0.isEmpty ? nil : " via \($0)" } ?? "")
    }

    /// Пользователь `DOMAIN\user` → домен и имя.
    private var splitUser: (user: String, domain: String?) {
        let parts = desktop.user.split(separator: "\\", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[1], parts[0]) : (desktop.user, nil)
    }

    /// Вкладка закрыта: запуск, который ещё ждёт (туннель, задержка перед стартом), не должен поднять соединение без вкладки.
    @ObservationIgnored private var closed = false

    func close() {
        closed = true
        disconnect()
    }

    func start() async {
        guard !closed else { return }
        target = (desktop.address, desktop.port)
        if let t = desktop.tunnel(localPort: RemoteDesktop.freeLocalPort()) {
            phase = .tunneling
            model.tunnels.start(t, hosts: model.hosts)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if case .failed(let m) = model.tunnels.status(of: t) { phase = .disconnected(L("SSH-туннель: %@", "\(m)")); return }
                if model.tunnels.status(of: t) == .running { break }
            }
            guard model.tunnels.status(of: t) == .running else {
                model.tunnels.stop(t.id)
                phase = .disconnected(L("SSH-туннель не поднялся за %@ с", "10"))
                return
            }
            tunnel = t
            if closed { model.tunnels.stop(t.id); tunnel = nil; return }
            target = ("localhost", t.listenPort)
        }
        if let saved = savedPassword(), !desktop.user.isEmpty {
            launch(user: splitUser.user, domain: splitUser.domain, password: saved)
        } else {
            phase = .needsCredentials
        }
    }

    /// Ответ из окна ввода учётных данных.
    func provide(user: String, password: String, save: Bool) {
        let parts = user.split(separator: "\\", maxSplits: 1).map(String.init)
        let (name, domain) = parts.count == 2 ? (parts[1], Optional(parts[0])) : (user, nil)
        // Имя из формы входа становится пользователем подключения; пароль сохраняется под его записью
        // только после успешного входа (как К12 на Windows), чтобы неверный пароль не попадал в Keychain.
        if save {
            var updated = desktop
            updated.user = user
            pendingSave = (password, updated.keychainAccount)
            if desktop.user != user { persist { $0.user = user } }
        } else {
            pendingSave = nil
        }
        launch(user: name, domain: domain, password: password)
    }

    func disconnect() {
        let e = engine
        engine = nil
        canvas.engine = nil
        canvas.releaseAll()
        audio.stop()
        e?.disconnect()
        if let t = tunnel { model.tunnels.stop(t.id) }
        tunnel = nil
        if phase == .connected || phase == .connecting { phase = .disconnected(nil) }
    }

    func forgetCertificate() {
        UserDefaults.standard.removeObject(forKey: certificateKey)
    }

    // MARK: - Сессия

    private func launch(user: String, domain: String?, password: String) {
        let name = user.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            phase = .disconnected(L("Укажите имя пользователя."))
            return
        }
        phase = .connecting
        certificateMismatch = false
        let scale = canvas.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let points = canvas.bounds.size.width > 100 ? canvas.bounds.size : CGSize(width: 1440, height: 900)
        surface = (points, scale)
        let size = desiredSize(points: points, scale: scale)
        lastSize = size

        let owner = WeakSession(self)
        var events = RDPEngine.Events()
        events.connected = { w, h in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.connected(w, h) } } }
        events.resized = { w, h in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.canvas.reset(width: w, height: h) } } }
        events.frame = { rects in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.canvas.apply(rects) } } }
        events.certificate = { sha, _ in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.askTrust(sha) } } }
        events.closed = { kind, message in
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.finished(kind, message) } }
        }
        events.clipboard = { text in DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.remoteClipboard(text) } } }
        // Звук — на своей очереди, не через главный поток (иначе пакеты PCM грузят UI и звук заикается).
        let audio = self.audio
        events.audio = { format, pcm in audio.play(format, pcm) }
        events.audioVolume = { v in audio.setServerVolume(v) }

        let trusted = UserDefaults.standard.string(forKey: certificateKey)
        certificate = trusted
        let engine = RDPEngine(config: .init(host: target.host, port: target.port, user: name, password: password,
                                             domain: domain?.trimmingCharacters(in: .whitespaces), width: size.0, height: size.1,
                                             scalePercent: scalePercent, trustedCertificate: trusted,
                                             gatewayHost: desktop.gatewayHost.flatMap { $0.isEmpty ? nil : $0 },
                                             gatewayUser: desktop.gatewayUser.flatMap { $0.isEmpty ? nil : $0 },
                                             gatewayPassword: try? keychain.password(for: desktop.gatewayKeychainAccount),
                                             gatewayDomain: desktop.gatewayDomain.flatMap { $0.isEmpty ? nil : $0 },
                                             h264LibraryPath: OpenH264.libraryPath),
                               events: events)
        self.engine = engine
        canvas.engine = engine
        engine.connect()
    }

    private func askTrust(_ fingerprint: String) {
        trustPromptChanged = UserDefaults.standard.string(forKey: certificateKey) != nil
        trustPrompt = fingerprint
    }

    private func connected(_ width: Int, _ height: Int) {
        if let p = pendingSave { try? keychain.setPassword(p.password, for: p.account) }
        pendingSave = nil
        canvas.reset(width: width, height: height)
        phase = .connected
        // «Во весь экран» из настроек стола — один раз при первом подключении (как К11 на Windows).
        if desktop.fullScreen, let w = canvas.window, !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        canvas.window?.makeFirstResponder(canvas)
        sendLocalClipboard()
        scheduleResize(delay: .milliseconds(200))
    }

    private func finished(_ kind: RDPEngine.CloseKind, _ message: String) {
        guard engine != nil else { return }   // закрыли сами
        engine = nil
        canvas.engine = nil
        audio.stop()
        trustPrompt = nil
        if let t = tunnel { model.tunnels.stop(t.id) }
        tunnel = nil
        switch kind {
        case .closedByUser:
            phase = .disconnected(nil)
        case .authFailed:
            pendingSave = nil
            try? keychain.deletePassword(for: account)
            phase = .needsCredentials
        case .certRejected:
            phase = certificateMismatch
                ? .disconnected(L("Сертификат сервера изменился с прошлого подключения. Если это ожидаемо (сервер переустановили), сбросьте доверие и подключитесь снова."))
                : .disconnected(nil)
        default:
            phase = .disconnected(message.isEmpty ? nil : SSHErrorText.describeRemote(.rdp, message))
        }
    }
}

/// Слабая ссылка на сессию для колбэков ядра. Читается только на главном потоке.
private final class WeakSession: @unchecked Sendable {
    weak var value: RDPSession?
    init(_ value: RDPSession) { self.value = value }
}
