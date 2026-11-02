import AppKit
import Observation
import RelayaCore

/// Запускает туннели фоновыми процессами `ssh -N` и следит за их состоянием.
@MainActor
@Observable
final class TunnelManager {
    enum Status: Equatable {
        case stopped, starting, running
        case failed(String)
    }

    private let store = TunnelStore()
    private let keychain = KeychainStore()
    private let askpassExecutable: String

    private(set) var tunnels: [Tunnel] = []
    private(set) var status: [Tunnel.ID: Status] = [:]
    /// Временные туннели, которых нет в списке (порт из вывода терминала, удалённый стол через SSH) —
    /// показываются в строке меню, пока запущены (UI-M5).
    private(set) var transient: [Tunnel.ID: Tunnel] = [:]
    var saveError: String?

    @ObservationIgnored private var processes: [Tunnel.ID: Process] = [:]
    @ObservationIgnored private var stopping: Set<Tunnel.ID> = []
    /// Туннели, ждущие Touch ID: остановка или удаление отменяют ожидание.
    @ObservationIgnored private var pendingAuth: [Tunnel.ID: Task<Void, Never>] = [:]
    /// Н4: автозапускаемый туннель, упавший после подъёма (обрыв сети, перезагрузка сервера), перезапускается
    /// с паузой 5 → 10 → 20 → 40 → 60 с; после 8 неудач подряд — остаётся в ошибке до ручного запуска.
    @ObservationIgnored private var retries: [Tunnel.ID: Int] = [:]
    @ObservationIgnored private var retryTasks: [Tunnel.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastHosts: [SSHHost] = []
    private static let maxRetries = 8
    /// Tunnels that came up since the user started them: only these are restarted on their own (B-3).
    @ObservationIgnored private var wasUp: Set<Tunnel.ID> = []

    init(askpassExecutable: String) {
        self.askpassExecutable = askpassExecutable
        tunnels = store.load()
        // ssh-процессы не умирают вместе с приложением сами — гасим их при выходе.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    var activeCount: Int { status.values.filter { $0 == .running || $0 == .starting }.count }

    func status(of tunnel: Tunnel) -> Status { status[tunnel.id] ?? .stopped }

    var anyRunning: Bool { status.values.contains { $0 == .running || $0 == .starting } }

    // MARK: - Список

    /// Перечитать список с диска (после синхронизации).
    func reloadFromDisk() {
        tunnels = store.load()
    }

    func upsert(_ tunnel: Tunnel) {
        if let i = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            let wasRunning = processes[tunnel.id] != nil
            tunnels[i] = tunnel
            if wasRunning { stop(tunnel.id) }
        } else {
            tunnels.append(tunnel)
        }
        persist()
    }

    func delete(_ id: Tunnel.ID) {
        stop(id)
        tunnels.removeAll { $0.id == id }
        status[id] = nil
        persist()
    }

    private func persist() {
        do { try store.save(tunnels) } catch { saveError = error.localizedDescription }
    }

    // MARK: - Процессы

    func startAutoStart(hosts: [SSHHost]) {
        for t in tunnels where t.autoStart { start(t, hosts: hosts) }
    }

    func start(_ tunnel: Tunnel, hosts: [SSHHost]) {
        guard processes[tunnel.id] == nil else { return }
        lastHosts = hosts
        retryTasks.removeValue(forKey: tunnel.id)?.cancel()
        if !tunnels.contains(where: { $0.id == tunnel.id }) { transient[tunnel.id] = tunnel }
        let host = hosts.first { $0.alias == tunnel.hostAlias }
        let usePassword = host.map { keychain.hasPassword(for: $0.keychainAccount) && !$0.usesKey } ?? false
        // Пароль из Keychain — только после Touch ID.
        if usePassword, !SecretGate.shared.isUnlocked {
            guard pendingAuth[tunnel.id] == nil else { return }
            status[tunnel.id] = .starting
            pendingAuth[tunnel.id] = Task { @MainActor in
                let ok = await SecretGate.shared.authorize(L("Запустить туннель «%@»", tunnel.name.isEmpty ? tunnel.spec : tunnel.name))
                self.pendingAuth[tunnel.id] = nil
                // Пока ждали Touch ID, туннель могли остановить, удалить или изменить — тогда не запускаем.
                guard !Task.isCancelled, self.tunnels.first(where: { $0.id == tunnel.id }) == tunnel else { return }
                if ok {
                    self.status[tunnel.id] = .stopped
                    self.start(tunnel, hosts: hosts)
                } else {
                    self.status[tunnel.id] = .failed(L("Touch ID не подтверждён — пароль из Keychain не использован."))
                }
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = tunnel.sshArguments(passwordOnly: usePassword)
        if usePassword, let host {
            let installer = KeyInstaller(askpassExecutable: askpassExecutable)
            let env = installer.askpassEnvironment(.init(store: keychain, account: host.keychainAccount, kind: .password, alias: host.alias))
            process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        let errHandle = err.fileHandleForReading
        let id = tunnel.id
        process.terminationHandler = { p in
            let message = String(decoding: errHandle.readDataToEndOfFile(), as: UTF8.self)
            let code = p.terminationStatus
            Task { @MainActor [weak self] in self?.exited(id, code: code, stderr: message) }
        }

        do {
            try process.run()
        } catch {
            status[id] = .failed(error.localizedDescription)
            return
        }
        processes[id] = process
        status[id] = .starting
        // ssh -N молчит при успехе: если через пару секунд жив — проброс поднят.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.processes[id]?.isRunning == true {
                self?.status[id] = .running
                self?.wasUp.insert(id)
            }
            // Проработал минуту — сеть в порядке, счётчик неудач сбрасывается.
            try? await Task.sleep(for: .seconds(58))
            if self?.processes[id]?.isRunning == true { self?.retries[id] = nil }
        }
    }

    func stop(_ id: Tunnel.ID) {
        retryTasks.removeValue(forKey: id)?.cancel()
        retries[id] = nil
        wasUp.remove(id)
        if let pending = pendingAuth.removeValue(forKey: id) {
            pending.cancel()
            status[id] = .stopped
        }
        guard let p = processes[id] else { return }
        stopping.insert(id)
        p.terminate()
    }

    func stopAll() {
        for id in processes.keys { stop(id) }
    }

    private func exited(_ id: Tunnel.ID, code: Int32, stderr: String) {
        processes[id] = nil
        transient[id] = nil
        if stopping.remove(id) != nil {
            status[id] = .stopped
            return
        }
        let reason = SSHErrorText.describe(stderr, fallback: L("ssh завершился с кодом %@", "\(code)"))
        // B-3: a refused login or a cut before login is not retried (the same credentials would only feed fail2ban),
        // and neither is a tunnel that never came up; the user fixes the host and starts it again.
        let refused = SSHErrorText.loginRefused(stderr)
        guard let tunnel = tunnels.first(where: { $0.id == id }), tunnel.autoStart, !refused, wasUp.contains(id) else {
            retries[id] = nil
            // V-3: the password hint only for a refused login; a cut before login says to wait in its own text.
            let wrongCredentials = refused && !SSHErrorText.loginBlocked(stderr)
            status[id] = .failed(wrongCredentials ? reason + "\n" + L("Исправьте пароль или ключ в карточке хоста и запустите туннель снова.") : reason)
            return
        }
        let attempt = (retries[id] ?? 0) + 1
        guard attempt <= Self.maxRetries else {
            retries[id] = nil
            status[id] = .failed(reason)
            return
        }
        retries[id] = attempt
        let delay = min(60, 5 << (attempt - 1))
        status[id] = .failed(reason + "\n" + L("Переподключение через %@ с (попытка %@ из %@)", "\(delay)", "\(attempt)", "\(Self.maxRetries)"))
        retryTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let t = self.tunnels.first(where: { $0.id == id }) else { return }
            self.retryTasks[id] = nil
            self.start(t, hosts: self.lastHosts)
        }
    }
}
