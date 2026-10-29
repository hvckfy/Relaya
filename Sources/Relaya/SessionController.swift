import AppKit
import SwiftUI
import Observation
import SwiftTerm
import RelayaCore

/// Состояние одной вкладки: распознаёт запросы ssh в выводе терминала и управляет переподключением.
@MainActor
@Observable
final class SessionController {
    let host: SSHHost
    private let keychain = KeychainStore()

    @ObservationIgnored weak var terminal: RelayaTerminalView?
    /// Вызывается, когда ОС удалось угадать по приветствию сервера.
    @ObservationIgnored var onOSGuessed: ((ServerOS) -> Void)?
    @ObservationIgnored private var osGuessed = false

    /// Меняется при переподключении — пересоздаёт терминал.
    private(set) var generation = 0

    /// Отпечаток нового сервера, ждущий решения пользователя.
    var hostKeyPrompt: String?
    var hostKeyChanged = false
    /// ssh спрашивает пароль, а в Keychain его нет.
    var passwordPromptWithoutSaved = false
    /// Сохранённый пароль не подошёл.
    var savedPasswordRejected = false
    /// Вошли по паролю — предложить ключ.
    var offerKeySetup = false

    private(set) var exitCode: Int32?
    private(set) var ended = false
    var reconnectIn: Int?

    @ObservationIgnored private var tail = ""
    @ObservationIgnored private var autofilled = false
    @ObservationIgnored private var sawPasswordPrompt = false
    @ObservationIgnored private var loggedIn = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    init(host: SSHHost) {
        self.host = host
    }

    // MARK: - Вывод терминала

    func handleOutput(_ text: String) {
        tail = String((tail + text).suffix(2000))

        if !osGuessed, host.os == nil, let os = ServerOS.guess(fromBanner: tail) {
            osGuessed = true
            onOSGuessed?(os)
        }

        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            hostKeyChanged = true
        }
        if tail.contains("Are you sure you want to continue connecting"),
           tail.trimmingCharacters(in: .whitespaces).hasSuffix("?") {
            hostKeyPrompt = Self.fingerprint(in: tail) ?? "неизвестен"
            return
        }

        if PasswordPrompt.matches(tail) {
            handlePasswordPrompt()
            return
        }

        // Первый осмысленный вывод после ввода пароля — значит, вошли.
        if sawPasswordPrompt, !loggedIn,
           text.contains(where: \.isLetter), !text.contains("Permission denied") {
            loggedIn = true
            passwordPromptWithoutSaved = false
            if !host.usesKey { offerKeySetup = true }
        }
    }

    private func handlePasswordPrompt() {
        sawPasswordPrompt = true
        tail = ""
        if autofilled {
            // Второй запрос после автоподстановки — пароль в Keychain устарел.
            savedPasswordRejected = true
            return
        }
        if let pw = try? keychain.password(for: host.keychainAccount) {
            autofilled = true
            terminal?.send(txt: pw + "\r")
        } else {
            passwordPromptWithoutSaved = true
        }
    }

    static func fingerprint(in text: String) -> String? {
        guard let r = text.range(of: "key fingerprint is ", options: .backwards) else { return nil }
        return text[r.upperBound...].split(whereSeparator: { $0.isWhitespace || $0 == "." }).first.map(String.init)
    }

    // MARK: - Действия из баннеров

    func answerHostKey(trust: Bool) {
        hostKeyPrompt = nil
        tail = ""
        terminal?.send(txt: trust ? "yes\r" : "no\r")
    }

    /// Пользователь ввёл пароль в наше поле: сохраняем (по желанию) и отправляем в ssh.
    func submitPassword(_ password: String, save: Bool) throws {
        if save { try keychain.setPassword(password, for: host.keychainAccount) }
        passwordPromptWithoutSaved = false
        savedPasswordRejected = false
        autofilled = true
        terminal?.send(txt: password + "\r")
    }

    // MARK: - Завершение и переподключение

    func processEnded(code: Int32?, autoReconnect: Bool) {
        ended = true
        exitCode = code
        hostKeyPrompt = nil
        // 255 — ошибка соединения ssh. Переподключаемся, только если сессия успела поработать.
        if autoReconnect, code == 255, loggedIn || Date().timeIntervalSince(startedAt) > 10 {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectIn = 5
        reconnectTask = Task { [weak self] in
            while let self, let left = self.reconnectIn, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.reconnectIn = left - 1
            }
            self?.reconnect()
        }
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectIn = nil
    }

    func reconnect() {
        cancelReconnect()
        ended = false
        exitCode = nil
        tail = ""
        autofilled = false
        sawPasswordPrompt = false
        loggedIn = false
        hostKeyPrompt = nil
        hostKeyChanged = false
        passwordPromptWithoutSaved = false
        savedPasswordRejected = false
        startedAt = Date()
        generation += 1
    }

    func terminate() {
        cancelReconnect()
        terminal?.terminate()
    }

    /// Вставляет команду в терминал без Enter — пользователь проверяет и запускает сам.
    func insert(_ command: String) {
        terminal?.send(txt: command)
        terminal?.window?.makeFirstResponder(terminal)
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminal?.performFindPanelAction(item)
    }
}

/// Терминал с перехватом вывода и завершения процесса.
final class RelayaTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?(String(decoding: slice, as: UTF8.self))
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onExit?(exitCode)
    }
}

/// Терминал запускает системный `/usr/bin/ssh` — так ~/.ssh/config, ssh-agent, Keychain
/// и ProxyJump работают ровно как в Terminal.app.
struct TerminalView: NSViewRepresentable {
    @Environment(AppSettings.self) private var settings
    let controller: SessionController

    func makeNSView(context: Context) -> RelayaTerminalView {
        let view = RelayaTerminalView(frame: .zero)
        apply(to: view)
        controller.terminal = view
        view.onOutput = { [weak controller] text in controller?.handleOutput(text) }
        let autoReconnect = settings.autoReconnect
        view.onExit = { [weak controller] code in controller?.processEnded(code: code, autoReconnect: autoReconnect) }
        view.startProcess(executable: "/usr/bin/ssh", args: [controller.host.alias])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: RelayaTerminalView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: RelayaTerminalView) {
        let theme = settings.theme
        if view.font != settings.font { view.font = settings.font }
        view.nativeBackgroundColor = theme.backgroundColor
        view.nativeForegroundColor = theme.foregroundColor
        view.caretColor = theme.foregroundColor
        view.optionAsMetaKey = settings.optionAsMeta
        view.installColors(theme.ansiColors)
    }
}
