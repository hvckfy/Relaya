import Foundation
import RelayaRust

/// Какие хосты ходят с ключом (IdentityFile + IdentitiesOnly yes) — логика в ядре, общая с Windows.
public enum KeyHosts {
    /// Путь для IdentityFile: внутри ~/.ssh — `~/.ssh/имя`, иначе как есть.
    public static func identityPath(_ absolute: String) -> String {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh").path + "/"
        return absolute.hasPrefix(ssh) ? "~/.ssh/" + absolute.dropFirst(ssh.count) : absolute
    }

    /// Все хосты конфига, включая git-серверы и общие блоки.
    public static func allAliases(_ text: String) -> [String] { configAllAliases(text: text) }

    public static func hosts(_ text: String, key: String) -> [String] { configKeyHosts(text: text, key: key) }

    /// Новый текст конфига: ключ стоит ровно у этих хостов.
    public static func bind(_ text: String, key: String, hosts: [String]) -> String {
        configBindKey(text: text, key: identityPath(key), hosts: hosts)
    }
}
