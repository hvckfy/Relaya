import Foundation
import LocalAuthentication

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
    private var clientName = "агент"

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
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }   // уведомления (notifications/initialized и т.п.)

        let result: [String: Any]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String { clientName = name }
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "relaya", "version": Self.version],
                "instructions": "Доступ к SSH-серверам пользователя из ~/.ssh/config. Права на каждый хост задаёт пользователь в приложении Relaya; команды на хостах «с подтверждением» он одобряет вручную.",
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await call(name, args)
            result = ["content": [["type": "text", "text": text]], "isError": isError]
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: - Инструменты

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        [
            "name": "list_hosts",
            "description": "Список SSH-хостов пользователя с адресом, ОС, группой, метками и уровнем доступа агента.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "run_command",
            "description": "Выполнить shell-команду на хосте по SSH. В режиме «только чтение» разрешены лишь безопасные команды без перенаправлений; в режиме «с подтверждением» пользователь одобряет каждую команду.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "host": ["type": "string", "description": "Алиас хоста из list_hosts"],
                    "command": ["type": "string", "description": "Команда для выполнения"],
                    "timeout_seconds": ["type": "integer", "description": "Таймаут, по умолчанию 60, максимум 600"],
                ],
                "required": ["host", "command"],
            ],
        ],
        [
            "name": "read_file",
            "description": "Прочитать файл на хосте (не больше max_bytes, по умолчанию 65536). Считается операцией чтения.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "host": ["type": "string"],
                    "path": ["type": "string"],
                    "max_bytes": ["type": "integer"],
                ],
                "required": ["host", "path"],
            ],
        ],
    ]

    private func call(_ name: String, _ args: [String: Any]) async -> (String, Bool) {
        let policy = policy()
        guard policy.enabled else { return ("Доступ агентов выключен в Relaya (раздел «Агенты»).", true) }

        switch name {
        case "list_hosts":
            let list = hosts().filter { policy.mode(for: $0.alias) != .off }.map { h -> [String: Any] in
                [
                    "host": h.alias, "address": h.subtitle, "os": h.os?.title ?? "неизвестно",
                    "group": h.group ?? "", "tags": h.tags, "access": policy.mode(for: h.alias).rawValue,
                ]
            }
            return (Self.encode(["hosts": list]) ?? "[]", false)

        case "run_command", "read_file":
            guard let alias = args["host"] as? String, let host = hosts().first(where: { $0.alias == alias }) else {
                return ("Хост не найден. Вызовите list_hosts.", true)
            }
            let command: String
            let isRead: Bool
            if name == "read_file" {
                guard let path = args["path"] as? String, !path.isEmpty else { return ("Укажите path.", true) }
                let limit = min(max(args["max_bytes"] as? Int ?? 65536, 1), 1_048_576)
                command = "head -c \(limit) -- \(Self.shellQuote(path))"
                isRead = true
            } else {
                guard let c = args["command"] as? String, !c.isEmpty else { return ("Укажите command.", true) }
                command = c
                isRead = MCPPolicy.isReadOnly(c)
            }
            let timeout = Duration.seconds(min(max(args["timeout_seconds"] as? Int ?? 60, 1), 600))

            let decision: String
            switch policy.mode(for: alias) {
            case .off:
                record(name, alias, command, "запрещено: нет доступа")
                return ("У агента нет доступа к хосту \(alias).", true)
            case .readOnly:
                guard isRead else {
                    record(name, alias, command, "запрещено: только чтение")
                    return ("Хост \(alias) открыт только для чтения, а эта команда может что-то изменить. Попросите пользователя выполнить её самому или повысить доступ в Relaya.", true)
                }
                decision = "разрешено: чтение"
            case .confirm:
                guard await confirm(host, command, clientName) else {
                    record(name, alias, command, "отклонено пользователем")
                    return ("Пользователь отклонил выполнение команды на \(alias).", true)
                }
                decision = "одобрено пользователем"
            case .trusted:
                decision = "разрешено: доверенный"
            }

            let r = await execute(host, command, timeout)
            record(name, alias, command, decision, exit: r.status)
            var text = r.stdout
            if !r.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + r.stderr }
            if text.count > 50_000 { text = String(text.prefix(50_000)) + "\n…[вывод обрезан]" }
            text += "\n[exit code: \(r.status)]"
            return (text, r.status != 0)

        default:
            return ("Неизвестный инструмент \(name).", true)
        }
    }

    private func record(_ tool: String, _ host: String, _ detail: String, _ decision: String, exit: Int32? = nil) {
        log?.append(MCPLogEntry(client: clientName, tool: tool, host: host, detail: detail, decision: decision, exitCode: exit))
    }

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
            let shown = command.count > 160 ? String(command.prefix(160)) + "…" : command
            let reason = "\(client) хочет выполнить на \(host.alias): \(shown)"
            return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        }
        return await askWithButtons(host: host, command: command, client: client)
    }

    /// Запасной вариант: диалог osascript, «Запретить» по умолчанию, без ответа за 2 минуты — отказ.
    static func askWithButtons(host: SSHHost, command: String, client: String) async -> Bool {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let shown = command.count > 600 ? String(command.prefix(600)) + "…" : command
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
