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

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let points = canvas.bounds.size.width > 100 ? canvas.bounds.size : CGSize(width: 1440, height: 900)
        var configuration = RDPConnectionConfiguration(
            host: target.host,
            port: UInt16(target.port),
            credentials: credentials,
            timeoutSeconds: 15,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: UInt16(min(points.width * scale, 7680)) & ~1,
            desktopHeight: UInt16(min(points.height * scale, 4320)) & ~1,
            clipboardEnabled: false,
            audioPlaybackEnabled: false,
            clientName: "Relaya"
        )
        configuration.scaleFactors = RDPDisplayScaleFactors(backingScaleFactor: scale)

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
