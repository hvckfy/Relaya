import Foundation
import RelayaCore

// Askpass-режим: ssh запускает этот же бинарник с текстом запроса в аргументе. Секрет выдаёт брокер процесса
// Relaya, запустившего ssh (по одноразовому токену и только своему потомку) — сам Keychain здесь не читается.
// Старый способ (имя записи в окружении) больше не работает: так пароль мог получить любой процесс.
let env = ProcessInfo.processInfo.environment
if env["RELAYA_ASKPASS_ACCOUNT"] != nil { exit(1) }
if let socket = env["RELAYA_ASKPASS_SOCKET"], let token = env["RELAYA_ASKPASS_TOKEN"] {
    let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
    if let secret = AskpassBroker.request(socket: socket, token: token, prompt: prompt) {
        print(secret)
        exit(0)
    }
    exit(1)
}

// Потоковые передачи SFTP пишут в pipe ssh: при обрыве нужна ошибка записи, а не падение.
signal(SIGPIPE, SIG_IGN)

// MCP-режим для AI-агентов: `Relaya --mcp` — JSON-RPC через stdin/stdout, без окна.
if CommandLine.arguments.contains("--mcp") {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    await MCPServer.standard(askpassExecutable: executable).run()
    exit(0)
}

// Демо-режим для скриншотов: вымышленные хосты и ключи во временной папке.
if CommandLine.arguments.contains("--demo") {
    RelayaPaths.demoRoot = DemoData.prepare()
}

RelayaApp.main()
