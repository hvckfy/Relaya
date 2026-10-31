import Foundation
import Security

/// Пароли серверов в системном Keychain (generic password).
///
/// Ключ записи — адрес подключения (`user@host:port`), а не алиас: переименование хоста
/// в ~/.ssh/config не теряет пароль.
public struct KeychainStore: Sendable {
    public var service: String

    public init(service: String = "app.relaya.ssh-password") {
        self.service = service
    }

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? L("код %@", "\(s)")
                return "Keychain: \(msg)"
            }
        }
    }

    public func password(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    public func hasPassword(for account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        // Только наличие записи — без чтения секрета, поэтому без запроса доступа у пользователя.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func setPassword(_ password: String, for account: String) throws {
        let data = Data(password.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Relaya — \(account)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func deletePassword(for account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    /// Переносит пароль при смене адреса/пользователя/порта хоста.
    public func movePassword(from old: String, to new: String) throws {
        guard old != new, let pw = try password(for: old) else { return }
        try setPassword(pw, for: new)
        try deletePassword(for: old)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension SSHHost {
    /// Запись Keychain для пароля этого хоста.
    public var keychainAccount: String {
        "\(user ?? NSUserName())@\(hostName ?? alias):\(port ?? 22)"
    }
}

/// Распознаёт приглашение ssh ввести пароль сервера в выводе терминала.
public enum PasswordPrompt {
    /// `user@host's password:`, `Password:`, `(user@host) Password:` — в конце вывода.
    /// Не срабатывает на passphrase ключа, sudo и прочие запросы после входа.
    public static func matches(_ tail: String) -> Bool {
        let line = tail.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasSuffix("password:") else { return false }
        return !t.contains("sudo") && !t.contains("passphrase") && !t.contains("new password")
            && !t.contains("current password")
    }

    /// Запрос пароля sudo в конце вывода: `[sudo] password for alex:` (Linux) или `[sudo] пароль для alex:`.
    public static func isSudo(_ tail: String) -> Bool {
        let line = tail.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("[sudo]") && t.hasSuffix(":")
    }
}
