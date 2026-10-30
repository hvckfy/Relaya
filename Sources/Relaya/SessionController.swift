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
    /// Живой терминал этой сессии: при перерисовке окна (смена темы) берём его, а не запускаем ssh заново.
    @ObservationIgnored var liveView: (view: RelayaTerminalView, generation: Int)?
    /// Вызывается, когда ОС удалось угадать по приветствию сервера.
    @ObservationIgnored var onOSGuessed: ((ServerOS) -> Void)?
    /// Пользователь что-то набрал в этом терминале.
    @ObservationIgnored var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    @ObservationIgnored private var osGuessed = false
    @ObservationIgnored private var retryPasswordOnly = false
    /// Команда, которую нужно выполнить после входа (например, из мастера ключей).
    @ObservationIgnored var pendingCommand: String?
    /// Имя постоянной сессии tmux на сервере (если для хоста включено).
    /// Можно включить и выключить в открытой вкладке — тогда она переподключается.
    var tmuxName: String?
    let tmuxIdleMinutes: Int

    /// Меняется при переподключении — пересоздаёт терминал.
    private(set) var generation = 0

    /// Отпечаток нового сервера, ждущий решения пользователя.
    var hostKeyPrompt: String?
    var hostKeyChanged = false
    /// Сервер оборвал вход после перебора ключей — переподключились сразу по паролю.
    private(set) var passwordOnly = false
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

    init(host: SSHHost, tmuxName: String? = nil, tmuxIdleMinutes: Int = 60) {
        self.host = host
        self.tmuxName = tmuxName
        self.tmuxIdleMinutes = tmuxIdleMinutes
    }

    // MARK: - Вывод терминала

    func handleOutput(_ text: String) {
        tail = String((tail + text).suffix(2000))

        if !osGuessed, host.os == nil, let os = ServerOS.guess(fromBanner: tail) {
            osGuessed = true
            onOSGuessed?(os)
        }

        if !passwordOnly, text.contains("Too many authentication failures") {
            // ssh перебрал ключи из агента, и сервер закрыл соединение до запроса пароля.
            passwordOnly = true
            retryPasswordOnly = true
        }
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            hostKeyChanged = true
        }
        if tail.contains("Are you sure you want to continue connecting"),
           tail.trimmingCharacters(in: .whitespaces).hasSuffix("?") {
            hostKeyPrompt = Self.fingerprint(in: tail) ?? L("неизвестен")
            return
        }

        if PasswordPrompt.matches(tail) {
            handlePasswordPrompt()
            return
        }

        if let cmd = pendingCommand, Self.looksLikeShellPrompt(tail) {
            pendingCommand = nil
            terminal?.sendQuiet(cmd + "\r")
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
        guard keychain.hasPassword(for: host.keychainAccount) else {
            passwordPromptWithoutSaved = true
            return
        }
        autofilled = true
        Task { @MainActor in
            // Touch ID перед подстановкой сохранённого пароля.
            guard await SecretGate.shared.authorize(L("Подставить сохранённый пароль для %@", host.alias)),
                  let pw = try? keychain.password(for: host.keychainAccount) else {
                autofilled = false
                passwordPromptWithoutSaved = true
                return
            }
            terminal?.sendQuiet(pw + "\r")
        }
    }

    /// Последняя строка заканчивается на `$`, `#`, `%` или `>` — shell ждёт ввода.
    static func looksLikeShellPrompt(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        let last = stripped.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let t = last.trimmingCharacters(in: .whitespaces)
        return ["$", "#", "%", ">"].contains { t.hasSuffix($0) }
    }

    static func fingerprint(in text: String) -> String? {
        guard let r = text.range(of: "key fingerprint is ", options: .backwards) else { return nil }
        return text[r.upperBound...].split(whereSeparator: { $0.isWhitespace || $0 == "." }).first.map(String.init)
    }

    // MARK: - Действия из баннеров

    func answerHostKey(trust: Bool) {
        hostKeyPrompt = nil
        tail = ""
        terminal?.sendQuiet(trust ? "yes\r" : "no\r")
    }

    /// Пользователь ввёл пароль в наше поле: сохраняем (по желанию) и отправляем в ssh.
    func submitPassword(_ password: String, save: Bool) throws {
        if save { try keychain.setPassword(password, for: host.keychainAccount) }
        passwordPromptWithoutSaved = false
        savedPasswordRejected = false
        autofilled = true
        terminal?.sendQuiet(password + "\r")
    }

    // MARK: - Завершение и переподключение

    func processEnded(code: Int32?, autoReconnect: Bool) {
        if retryPasswordOnly {
            retryPasswordOnly = false
            reconnect()
            return
        }
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
        defer { liveView = nil }
        terminal?.terminate()
    }

    /// Вставляет команду в терминал без Enter — пользователь проверяет и запускает сам.
    func insert(_ command: String) {
        terminal?.sendQuiet(command)
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
    /// Ввод, набранный пользователем в этом терминале (для рассылки в другие вкладки).
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    private var quiet = false
    var highlighter = TerminalHighlighter(rules: [])
    /// Набор правил, уже переданный в highlighter (чтобы не перекомпилировать на каждом обновлении).
    var appliedRules: [HighlightRule]?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // Подсвечиваем только целые UTF-8 куски; если символ разорван на границе — выводим как есть.
        if highlighter.isActive, let text = String(bytes: slice, encoding: .utf8) {
            feed(text: highlighter.process(text))
        } else {
            let pending = highlighter.flush()
            if !pending.isEmpty { feed(text: pending) }
            super.dataReceived(slice: slice)
        }
        onOutput?(String(decoding: slice, as: UTF8.self))
    }

    /// Программный ввод (пароль, ответ на запрос, сниппет): никогда не рассылается в другие вкладки.
    func sendQuiet(_ text: String) {
        quiet = true
        send(txt: text)
        quiet = false
    }

    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        if !quiet { onUserInput?(data) }
    }

    /// Ввод, разосланный из другой вкладки: прямо в процесс, без повторной рассылки.
    func receiveBroadcast(_ data: ArraySlice<UInt8>) {
        process?.send(data: data)
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
        if let live = controller.liveView, live.generation == controller.generation {
            apply(to: live.view)
            return live.view
        }
        defer { controller.liveView?.view.onUserInput = { [weak controller] data in controller?.onUserInput?(data) } }
        let view = RelayaTerminalView(frame: .zero)
        controller.liveView = (view, controller.generation)
        apply(to: view)
        controller.terminal = view
        view.onOutput = { [weak controller] text in controller?.handleOutput(text) }
        let autoReconnect = settings.autoReconnect
        view.onExit = { [weak controller] code in controller?.processEnded(code: code, autoReconnect: autoReconnect) }
        let options = controller.passwordOnly ? KeyInstaller.passwordOnlyOptions : []
        if RelayaPaths.isDemo {
            // Демо: локальная оболочка с приглашением «как на сервере», без сетевых подключений.
            view.startProcess(executable: "/bin/bash", args: ["--noprofile", "--norc", "-i"],
                              environment: DemoData.shellEnvironment(for: controller.host))
        } else {
            var args = options + [controller.host.alias]
            if let name = controller.tmuxName {
                args = options + ["-t", controller.host.alias,
                                  Tmux.attachCommand(name: name, ttlMinutes: controller.tmuxIdleMinutes)]
            }
            view.startProcess(executable: "/usr/bin/ssh", args: args)
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: RelayaTerminalView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: RelayaTerminalView) {
        let theme = settings.theme
        if view.font != settings.font { view.font = settings.font }
        // С картинкой фона терминал полупрозрачный: просвечивает общая картинка окна.
        view.nativeBackgroundColor = theme.backgroundColor.withAlphaComponent(ThemeStore.sessionOpacity)
        view.layer?.isOpaque = false
        view.nativeForegroundColor = theme.foregroundColor
        view.caretColor = theme.foregroundColor
        view.optionAsMetaKey = settings.optionAsMeta
        view.installColors(theme.ansiColors)
        let rules = settings.highlightEnabled ? settings.highlightRules : []
        if view.appliedRules != rules {
            view.highlighter.setRules(rules)
            view.appliedRules = rules
        }
    }
}
