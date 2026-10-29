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
    var saveError: String?

    @ObservationIgnored private var processes: [Tunnel.ID: Process] = [:]
    @ObservationIgnored private var stopping: Set<Tunnel.ID> = []

    init(askpassExecutable: String) {
        self.askpassExecutable = askpassExecutable
        tunnels = store.load()
        // ssh-процессы не умирают вместе с приложением сами — гасим их при выходе.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    var activeCount: Int { status.values.filter { $0 == .running || $0 == .starting }.count }

    func status(of tunnel: Tunnel) -> Status { status[tunnel.id] ?? .stopped }

    // MARK: - Список

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
        let host = hosts.first { $0.alias == tunnel.hostAlias }
        let usePassword = host.map { keychain.hasPassword(for: $0.keychainAccount) && !$0.usesKey } ?? false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = tunnel.sshArguments(passwordOnly: usePassword)
        if usePassword, let host {
            let installer = KeyInstaller(askpassExecutable: askpassExecutable)
            let env = installer.askpassEnvironment(.init(store: keychain, account: host.keychainAccount, kind: .password))
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
            if self?.processes[id]?.isRunning == true { self?.status[id] = .running }
        }
    }

    func stop(_ id: Tunnel.ID) {
        guard let p = processes[id] else { return }
        stopping.insert(id)
        p.terminate()
    }

    func stopAll() {
        for id in processes.keys { stop(id) }
    }

    private func exited(_ id: Tunnel.ID, code: Int32, stderr: String) {
        processes[id] = nil
        if stopping.remove(id) != nil {
            status[id] = .stopped
            return
        }
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh завершился с кодом \(code)"
        status[id] = .failed(line.contains("Permission denied")
            ? "Нужен вход без пароля: настройте ключ или сохраните пароль в Keychain. (\(line))"
            : line)
    }
}
