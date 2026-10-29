import Foundation
import RelayaCore

// Askpass-режим: ssh запускает этот же бинарник с текстом запроса в аргументе.
// Секрет читается из Keychain по имени записи из окружения и печатается только
// в ответ на ожидаемый запрос (пароль сервера или passphrase), иначе — отказ.
let env = ProcessInfo.processInfo.environment
if let account = env["RELAYA_ASKPASS_ACCOUNT"] {
    let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
    let store = KeychainStore(service: env["RELAYA_ASKPASS_SERVICE"] ?? KeychainStore().service)
    let expected = env["RELAYA_ASKPASS_KIND"] == "passphrase"
        ? prompt.lowercased().contains("passphrase")
        : PasswordPrompt.matches(prompt)
    if expected, let secret = try? store.password(for: account) {
        print(secret)
        exit(0)
    }
    exit(1)
}

RelayaApp.main()
