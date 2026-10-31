import AppKit
import Observation
import SwiftTerm
import RelayaCore

/// Окно tmux, показанное как вкладка Relaya (control mode).
@MainActor
@Observable
final class TmuxWindow {
    let id: String
    var pane: String
    var name: String
    unowned let client: TmuxControlClient

    /// Терминал без своего процесса: вывод приходит из `%output`, ввод уходит в `send-keys`.
    @ObservationIgnored private(set) lazy var view: TmuxPaneView = {
        let v = TmuxPaneView(frame: .zero)
        v.window_ = self
        v.terminalDelegate = v
        if !pending.isEmpty { v.feed(byteArray: pending[...]); pending = [] }
        return v
    }()
    @ObservationIgnored private var pending: [UInt8] = []
    @ObservationIgnored private var viewCreated = false

    init(id: String, pane: String, name: String, client: TmuxControlClient) {
        self.id = id
        self.pane = pane
        self.name = name
        self.client = client
    }

    /// До создания терминала вывод копится, но не больше ~1 МБ: старое отбрасывается (экран всё равно перерисуется).
    private static let pendingLimit = 1 << 20

    func receive(_ bytes: [UInt8]) {
        if viewCreated { view.feed(byteArray: bytes[...]); return }
        pending += bytes
        if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
    }

    func makeView() -> TmuxPaneView {
        viewCreated = true
        return view
    }
}

final class TmuxPaneView: SwiftTerm.TerminalView, @preconcurrency TerminalViewDelegate {
    weak var window_: TmuxWindow?

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            guard let w = window_ else { return }
            w.client.send(TmuxControl.sendKeys(pane: w.pane, data))
        }
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard let w = window_ else { return }
            w.client.send(TmuxControl.resize(window: w.id, cols: newCols, rows: newRows))
        }
    }

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        MainActor.assumeIsolated {
            if let port = LocalPorts.find(in: link).first, let w = window_ {
                w.client.onOpenServerPort?(port)
            } else if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(content, forType: .string)
    }
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// Одно соединение `ssh -tt host tmux -CC attach`: разбирает уведомления и держит окна сессии.
@MainActor
@Observable
final class TmuxControlClient {
    let host: SSHHost
    let sessionName: String
    private(set) var windows: [TmuxWindow] = []
    private(set) var ended = false
    var error: String?

    /// Модель создаёт и закрывает вкладки по этим событиям.
    @ObservationIgnored var onWindowAdded: ((TmuxWindow) -> Void)?
    @ObservationIgnored var onWindowClosed: ((TmuxWindow) -> Void)?
    @ObservationIgnored var onExit: (() -> Void)?
    @ObservationIgnored var onOpenServerPort: ((Int) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var parser = TmuxControl.Parser()
    /// Ответы приходят по порядку команд — очередь обработчиков.
    @ObservationIgnored private var replyHandlers: [([String], Bool) -> Void] = []

    init(host: SSHHost, sessionName: String) {
        self.host = host
        self.sessionName = sessionName
    }

    func start(_ ssh: SSHInvocation) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ssh.options + ["-tt", ssh.alias, TmuxControl.attachCommand(name: sessionName)]
        if !ssh.environment.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(ssh.environment) { $1 }
        }
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stdout
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let bytes = [UInt8](data)
            Task { @MainActor in self?.handle(bytes) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        do {
            try p.run()
            process = p
            // Сам attach отвечает своим %begin/%end (часто пустым) — у него свой обработчик, иначе этот ответ
            // забрал бы обработчик list-windows и окна не появились бы.
            replyHandlers.append { _, _ in }
            query(TmuxControl.listWindows) { [weak self] lines, _ in self?.syncWindows(lines) }
        } catch {
            self.error = error.localizedDescription
            finish()
        }
    }

    func send(_ command: String) {
        guard !ended else { return }
        try? input?.write(contentsOf: Data((command + "\n").utf8))
        // У каждой команды есть %begin/%end — держим очередь, даже если ответ не нужен.
        replyHandlers.append { _, _ in }
    }

    private func query(_ command: String, _ handler: @escaping ([String], Bool) -> Void) {
        guard !ended else { return }
        try? input?.write(contentsOf: Data((command + "\n").utf8))
        replyHandlers.append(handler)
    }

    func newWindow() { send(TmuxControl.newWindow) }

    func close(_ w: TmuxWindow) { send(TmuxControl.killWindow(w.id)) }

    /// Отключиться, оставив сессию на сервере (её закроет таймер, если не вернуться).
    func detach() {
        try? input?.write(contentsOf: Data("detach-client\n".utf8))
        process?.terminate()
    }

    private func handle(_ bytes: [UInt8]) {
        for event in parser.feed(bytes) {
            switch event {
            case .output(let pane, let data):
                windows.first { $0.pane == pane }?.receive(data)
            case .windowAdd:
                query(TmuxControl.listWindows) { [weak self] lines, _ in self?.syncWindows(lines) }
            case .windowClose(let id):
                if let i = windows.firstIndex(where: { $0.id == id }) {
                    let w = windows.remove(at: i)
                    onWindowClosed?(w)
                }
            case .windowRenamed(let id, let name):
                windows.first { $0.id == id }?.name = name
            case .windowPaneChanged(let id, let pane):
                windows.first { $0.id == id }?.pane = pane
            case .reply(let lines, let error):
                if !replyHandlers.isEmpty { replyHandlers.removeFirst()(lines, error) }
            case .exit:
                finish()
            }
        }
    }

    private func syncWindows(_ lines: [String]) {
        for info in TmuxControl.parseWindows(lines) {
            if let w = windows.first(where: { $0.id == info.window }) {
                w.pane = info.pane
                w.name = info.name
                continue
            }
            let w = TmuxWindow(id: info.window, pane: info.pane, name: info.name, client: self)
            windows.append(w)
            // Текущее содержимое экрана — сразу, дальше идут %output.
            query(TmuxControl.capture(pane: info.pane)) { [weak w] lines, error in
                guard !error, let w else { return }
                w.receive(Array(lines.joined(separator: "\r\n").utf8))
            }
            onWindowAdded?(w)
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        try? input?.close()
        onExit?()
    }
}
