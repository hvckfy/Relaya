import AppKit
import Observation
import RDPKit
import RelayaCore

/// Встроенный RDP-клиент на RDPKit: NLA, H.264, клавиатура и мышь (виды взяты из RDPeek).
/// Пароль — из Keychain или из окна ввода, сертификат сервера — доверие при первом подключении.
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
    /// Отпечаток сертификата сервера (SHA-256), когда он пришёл.
    private(set) var certificate: String?
    /// Подключение оборвано из-за смены сертификата сервера.
    private(set) var certificateMismatch = false
    /// Фиксированное разрешение (nil — по размеру окна) и масштаб; меняются на лету из меню окна.
    private(set) var fixedSize: (width: Int, height: Int)?
    private(set) var retina: Bool
    /// Сервер поддерживает смену разрешения без переподключения.
    private(set) var canResize = false
    @ObservationIgnored private var displayControl: RDPDisplayControlSession?
    @ObservationIgnored private var lastRequest: RDPDisplayRequest?
    @ObservationIgnored private var surface: (points: CGSize, scale: CGFloat)?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    /// Холст: экран удалённой машины и слой ввода.
    let canvas = RemoteDesktopCanvasNSView()

    @ObservationIgnored private var cancellation: RDPConnectionCancellation?
    @ObservationIgnored private var inputSession: RDPInputSession?
    @ObservationIgnored private var tunnel: Tunnel?
    @ObservationIgnored private var target: (host: String, port: Int) = ("", 0)
    @ObservationIgnored private var presented = 0

    init(desktop: RemoteDesktop, model: AppModel) {
        self.desktop = desktop
        self.model = model
        if let w = desktop.rdpWidth, let h = desktop.rdpHeight { fixedSize = (w, h) }
        retina = desktop.rdpRetina ?? true
        canvas.onSurfaceChange = { [weak self] points, scale in
            MainActor.assumeIsolated { self?.surfaceChanged(points: points, scale: scale) }
        }
    }

    // MARK: - Разрешение

    /// Запрос размера рабочего стола: пиксели окна (или фиксированные) и масштаб Retina/100%.
    private func displayRequest(points: CGSize, scale: CGFloat) -> RDPDisplayRequest {
        let scaleFactors = RDPDisplayScaleFactors(backingScaleFactor: retina ? scale : 1)
        if let fixedSize {
            return RDPDisplayRequest(width: UInt32(fixedSize.width), height: UInt32(fixedSize.height), scaleFactors: scaleFactors)
        }
        let w = UInt32(min(8192, max(640, (points.width * scale).rounded())))
        let h = UInt32(min(8192, max(480, (points.height * scale).rounded())))
        return RDPDisplayRequest(width: w, height: h, scaleFactors: scaleFactors)
    }

    private func surfaceChanged(points: CGSize, scale: CGFloat) {
        surface = (points, scale)
        guard fixedSize == nil else { return }
        scheduleResize()
    }

    /// Окно перестали тянуть — через полсекунды просим сервер перестроить рабочий стол.
    private func scheduleResize(delay: Duration = .milliseconds(500)) {
        guard displayControl != nil, let surface else { return }
        resizeTask?.cancel()
        let request = displayRequest(points: surface.points, scale: surface.scale)
        guard request != lastRequest else { return }
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let control = self.displayControl, request != self.lastRequest else { return }
            control.send(request)
            self.lastRequest = request
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

    fileprivate func displayControlReady(_ session: RDPDisplayControlSession) {
        displayControl = session
        canResize = true
        lastRequest = nil
        scheduleResize(delay: .milliseconds(200))
    }

    var account: String { "\(desktop.user)@\(desktop.address):\(desktop.port)" }
    private var certificateKey: String { "rdp.certificate.\(desktop.address):\(desktop.port)" }

    /// Пользователь `DOMAIN\user` → домен и имя.
    private var splitUser: (user: String, domain: String?) {
        let parts = desktop.user.split(separator: "\\", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[1], parts[0]) : (desktop.user, nil)
    }

    func start() async {
        target = (desktop.address, desktop.port)
        if let t = desktop.tunnel(localPort: RemoteDesktop.freeLocalPort()) {
            phase = .tunneling
            model.tunnels.start(t, hosts: model.hosts)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if case .failed(let m) = model.tunnels.status(of: t) { phase = .disconnected(L("SSH-туннель: %@", "\(m)")); return }
                if model.tunnels.status(of: t) == .running { break }
            }
            tunnel = t
            target = ("localhost", t.listenPort)
        }
        if let saved = try? keychain.password(for: account), !desktop.user.isEmpty {
            launch(user: splitUser.user, domain: splitUser.domain, password: saved)
        } else {
            phase = .needsCredentials
        }
    }

    /// Ответ из окна ввода учётных данных.
    func provide(user: String, password: String, save: Bool) {
        let parts = user.split(separator: "\\", maxSplits: 1).map(String.init)
        let (name, domain) = parts.count == 2 ? (parts[1], Optional(parts[0])) : (user, nil)
        if save { try? keychain.setPassword(password, for: account) }
        launch(user: name, domain: domain, password: password)
    }

    func disconnect() {
        cancellation?.cancel()
        cancellation = nil
        if let t = tunnel { model.tunnels.stop(t.id) }
        tunnel = nil
    }

    func forgetCertificate() {
        UserDefaults.standard.removeObject(forKey: certificateKey)
    }

    // MARK: - Сессия

    private func launch(user: String, domain: String?, password: String) {
        let credentials: RDPCredentials
        do {
            guard let valid = try RDPCredentials.validated(username: user, domain: domain, password: password) else {
                phase = .disconnected(L("Укажите имя пользователя и пароль."))
                return
            }
            credentials = valid
        } catch {
            phase = .disconnected(L("Учётные данные: %@", "\(error.localizedDescription)"))
            return
        }
        phase = .connecting
        presented = 0

        let scale = canvas.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let points = canvas.bounds.size.width > 100 ? canvas.bounds.size : CGSize(width: 1440, height: 900)
        let initial = displayRequest(points: points, scale: scale)
        displayControl = nil
        canResize = false
        lastRequest = initial
        var configuration = RDPConnectionConfiguration(
            host: target.host,
            port: UInt16(target.port),
            credentials: credentials,
            timeoutSeconds: 15,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: UInt16(min(initial.width, 8192)),
            desktopHeight: UInt16(min(initial.height, 8192)),
            clipboardEnabled: false,
            audioPlaybackEnabled: false,
            clientName: "Relaya"
        )
        configuration.scaleFactors = initial.scaleFactors

        let cancellation = RDPConnectionCancellation()
        self.cancellation = cancellation
        let knownCertificate = UserDefaults.standard.string(forKey: certificateKey)
        let certificateKey = certificateKey

        // Слабая ссылка, которую можно унести в поток сессии: обращения к ней — только через главный поток.
        let owner = WeakSession(self)
        // run() блокирует поток на всю сессию — отдельный Thread, не executor Swift Concurrency.
        let thread = Thread {
            let decodeQueue = RDPFrameDecodeQueue(
                shouldCancel: { cancellation.isCancelled },
                onDecoded: { presentation, _, _, _ in
                    nonisolated(unsafe) let presentation = presentation
                    DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.present(presentation) } }
                },
                onDecodeFailed: { _, _ in }
            )
            defer { decodeQueue.cancel() }

            let report = RDPSessionClient().run(
                configuration: configuration,
                onGraphicsFrame: { frame in
                    _ = decodeQueue.submitAndWait(frame, receivedAt: Date(), shouldContinue: { !cancellation.isCancelled })
                },
                onInputReady: { session in
                    nonisolated(unsafe) let session = session
                    DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.activated(session) } }
                },
                onDisplayControlReady: { session in
                    DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.displayControlReady(session) } }
                },
                onCertificate: { info in
                    let fingerprint = info.sha256
                    // Доверие при первом подключении: сменившийся сертификат — отказ до отправки пароля.
                    if let known = knownCertificate, let fingerprint, known != fingerprint {
                        cancellation.cancel()
                    } else if knownCertificate == nil, let fingerprint {
                        UserDefaults.standard.set(fingerprint, forKey: certificateKey)
                    }
                    DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.certificate = fingerprint } }
                },
                cancellation: cancellation
            )
            let message = report.error ?? ""
            let status = report.status
            let certificateChanged = knownCertificate != nil && cancellation.isCancelled
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner.value?.finished(status: status, message: message, certificateChanged: certificateChanged) }
            }
        }
        thread.name = "Relaya RDP"
        thread.qualityOfService = QualityOfService.userInitiated
        thread.start()
    }

    private func present(_ presentation: RDPDecodedFramePresentation) {
        presented += 1
        canvas.displayView.present(presentation, id: presented)
        canvas.update(frame: RDPFrameMetadata(presentation.frame), hasPresentedFrame: true, inputSession: inputSession)
        if presented == 1 {
            phase = .connected
            canvas.makeInputFirstResponder()
        }
    }

    private func activated(_ session: RDPInputSession) {
        inputSession = session
        canvas.update(frame: nil, hasPresentedFrame: false, inputSession: session)
    }

    private func finished(status: String, message: String, certificateChanged: Bool) {
        guard cancellation != nil || certificateChanged else {
            phase = .disconnected(nil)   // закрыли сами
            return
        }
        cancellation = nil
        inputSession = nil
        if let t = tunnel { model.tunnels.stop(t.id) }
        tunnel = nil
        certificateMismatch = certificateChanged
        if certificateChanged {
            phase = .disconnected(L("Сертификат сервера изменился с прошлого подключения. Если это ожидаемо (сервер переустановили), сбросьте доверие и подключитесь снова."))
            return
        }
        if status.localizedCaseInsensitiveContains("logon") || message.localizedCaseInsensitiveContains("logon") {
            try? keychain.deletePassword(for: account)
            phase = .disconnected(L("Неверное имя пользователя или пароль."))
            return
        }
        phase = .disconnected(message.isEmpty ? status : message)
    }
}

/// Слабая ссылка на сессию для потока RDPKit. Читается только на главном потоке.
private final class WeakSession: @unchecked Sendable {
    weak var value: RDPSession?
    init(_ value: RDPSession) { self.value = value }
}
