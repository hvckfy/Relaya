import Foundation
import LocalAuthentication
import RelayaRust

/// MCP-сервер Relaya: JSON-RPC 2.0 построчно через stdin/stdout.
///
/// Запускается как `Relaya --mcp`. Команды выполняются системным ssh с ключами
/// пользователя или паролем из Keychain; права — по `MCPPolicy`.
public final class MCPServer {
    public static let version = "0.5.0"

    /// Выполнение команды на хосте. Заменяется в тестах.
    public typealias Executor = (_ host: SSHHost, _ command: String, _ timeout: Duration) async -> ProcessResult
    /// Подтверждение от пользователя (системный диалог). Заменяется в тестах.
    public typealias Confirmer = (_ host: SSHHost, _ command: String, _ client: String) async -> Bool

    private let hosts: () -> [SSHHost]
    private let policy: () -> MCPPolicy
    private let log: MCPLog?
    private let execute: Executor
    private let confirm: Confirmer

    public init(hosts: @escaping () -> [SSHHost], policy: @escaping () -> MCPPolicy, log: MCPLog?,
                execute: @escaping Executor, confirm: @escaping Confirmer) {
        self.hosts = hosts
        self.policy = policy
        self.log = log
        self.execute = execute
        self.confirm = confirm
    }

    /// Обычная конфигурация: ~/.ssh/config, политика и журнал из Application Support, системные ssh и диалог.
    public static func standard(askpassExecutable: String) -> MCPServer {
        let keychain = KeychainStore()
        return MCPServer(
            hosts: { (try? SSHConfigParser.load()) ?? [] },
            policy: { MCPPolicyStore().load() },
            log: MCPLog(),
            execute: { host, command, timeout in
                var args = ["-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15"]
                var env: [String: String] = [:]
                if !host.usesKey, keychain.hasPassword(for: host.keychainAccount) {
                    env = KeyInstaller(askpassExecutable: askpassExecutable)
                        .askpassEnvironment(.init(store: keychain, account: host.keychainAccount, kind: .password))
                    args += KeyInstaller.passwordOnlyOptions
                } else {
                    args += ["-o", "BatchMode=yes"]
                }
                do {
                    return try await ProcessRunner.run("/usr/bin/ssh", args + [host.alias, command],
                                                       environment: env, timeout: timeout)
                } catch {
                    return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
                }
            },
            confirm: { host, command, client in
                await MCPServer.askWithDialog(host: host, command: command, client: client)
            }
        )
    }

    // MARK: - Цикл

    public func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    /// Обрабатывает одно сообщение; nil — ответ не нужен (уведомление).
    /// Сам протокол, права и журнал — в Rust-ядре (`core/src/mcp.rs`); ядро вызывает наш бэкенд синхронно,
    /// поэтому работает в отдельном потоке, а не в пуле Swift Concurrency.
    public func handle(_ line: String) async -> String? {
        let core = self.core
        return await withCheckedContinuation { cont in
            Thread.detachNewThread { cont.resume(returning: core.handle(line: line)) }
        }
    }

    private lazy var core = RelayaRust.McpServer(backend: Backend(owner: self))

    /// Мост «ядро → платформа»: хосты, политика, ssh, подтверждение, журнал.
    private final class Backend: McpBackend, @unchecked Sendable {
        unowned let owner: MCPServer
        init(owner: MCPServer) { self.owner = owner }

        /// Дождаться async-вызова из синхронного потока ядра.
        private func wait<T>(_ body: @escaping () async -> T) -> T {
            let box = UnsafeBox<T>()
            let sem = DispatchSemaphore(value: 0)
            // Поток ядра ждёт здесь, пока задача не закончится, — гонки нет.
            let work = UncheckedSendable(value: body)
            Task.detached { box.value = await work.value(); sem.signal() }
            sem.wait()
            return box.value!
        }

        func hosts() -> [RelayaRust.SshHost] { owner.hosts().map(\.rust) }
        func policy() -> McpPolicy { owner.policy().rust }

        func execute(host: RelayaRust.SshHost, command: String, timeoutSeconds: UInt32) -> ExecResult {
            let h = SSHHost(rust: host), run = owner.execute
            let r = wait { await run(h, command, .seconds(Int(timeoutSeconds))) }
            return ExecResult(status: r.status, stdout: r.stdout, stderr: r.stderr)
        }

        func confirm(host: RelayaRust.SshHost, command: String, client: String) -> Bool {
            let h = SSHHost(rust: host), ask = owner.confirm
            return wait { await ask(h, command, client) }
        }

        func log(entry: McpLogEntry) {
            let f = ISO8601DateFormatter()
            var e = MCPLogEntry(date: f.date(from: entry.date) ?? Date(), client: entry.client, tool: entry.tool, host: entry.host,
                                detail: entry.detail, decision: entry.decision, exitCode: entry.exitCode)
            e.session = entry.session.flatMap(UUID.init(uuidString:))
            e.changes = entry.changes
            e.output = entry.output
            owner.log?.append(e)
        }
    }

    private final class UnsafeBox<T>: @unchecked Sendable { var value: T? }
    private struct UncheckedSendable<V>: @unchecked Sendable { let value: V }

    // MARK: - Помощники

    static func encode(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Аргумент для POSIX sh в одинарных кавычках.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Подтверждение команды — системным окном Touch ID: приложить палец или ввести пароль Mac — разрешить,
    /// «Запретить» — отказ. Без Touch ID и пароля на Mac — обычный диалог с кнопками.
    static func askWithDialog(host: SSHHost, command: String, client: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Запретить"
        context.localizedFallbackTitle = "Ввести пароль"
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            // Окно Touch ID вмещает ~160 символов. Длинную команду сначала показываем целиком
            // (диалог, «Запретить» по умолчанию), и только потом просим Touch ID — подтверждается то, что видно.
            if command.count > 160 {
                guard await askWithButtons(host: host, command: command, client: client) else { return false }
                let reason = "Подтвердите команду \(client) на \(host.alias), показанную в предыдущем окне"
                return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
            }
            let reason = "\(client) хочет выполнить на \(host.alias): \(command)"
            return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        }
        return await askWithButtons(host: host, command: command, client: client)
    }

    /// Запасной вариант: диалог osascript, «Запретить» по умолчанию, без ответа за 2 минуты — отказ.
    static func askWithButtons(host: SSHHost, command: String, client: String) async -> Bool {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        // Команда целиком: подтверждать можно только то, что видно (обрезаем лишь совсем огромные, с пометкой).
        let shown = command.count > 4000 ? String(command.prefix(4000)) + "\n… (ещё \(command.count - 4000) символов — отклоните)" : command
        let tags = host.tags.isEmpty ? "" : " [\(host.tags.joined(separator: ", "))]"
        let script = """
        set answer to display dialog "\(esc(client)) хочет выполнить на \(esc(host.alias))\(esc(tags)):\n\n\(esc(shown))" ¬
            with title "Relaya — запрос агента" buttons {"Запретить", "Разрешить"} default button "Запретить" ¬
            cancel button "Запретить" with icon caution giving up after 120
        if gave up of answer then error number -128
        if button returned of answer is "Разрешить" then return "RELAYA_ALLOW"
        return "RELAYA_DENY"
        """
        // Ответ — ASCII: у процесса MCP бывает локаль без UTF-8, и osascript печатает кириллицу как «?»,
        // из-за чего «Разрешить» не совпадало и любое разрешение считалось отказом.
        guard let r = try? await ProcessRunner.run("/usr/bin/osascript", ["-e", script]) else { return false }
        return r.succeeded && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "RELAYA_ALLOW"
    }
}
