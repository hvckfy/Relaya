import Foundation
import RelayaRust

/// Одно ssh-соединение на хост для служебных операций (П-9): SFTP, диск, статистика, команды карточки хоста.
/// Интерактивные терминалы и окна tmux идут своими соединениями. Правила — в ядре (`ssh_mux.rs`): приватный каталог
/// сокетов 0700, без пересылок и агента; хосты, чей конфиг запускает программы, не мультиплексируются.
public enum SSHMux {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String: String] = [:]

    /// Параметры ssh/sftp для служебного вызова; пусто — без мультиплекса (каталог небезопасен или конфиг хоста
    /// запускает команды).
    public static func options(alias: String) -> [String] {
        guard KeyInstaller.passwordMayBeAutomated(alias: alias),
              let dir = try? sshMuxDir(base: NSTemporaryDirectory()) else { return [] }
        let path = sshMuxControlPath(dir: dir, alias: alias)
        lock.withLock { paths[alias] = path }
        return sshMuxOptions(controlPath: path)
    }

    /// Закрыть все master-соединения: выход из приложения, блокировка экрана, сон.
    public static func closeAll() {
        let all = lock.withLock { defer { paths.removeAll() }; return paths }
        for (alias, path) in all {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = sshMuxExitArgs(controlPath: path, alias: alias)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                NSLog("Relaya SSH: master %@ не закрыт: %@", alias, error.localizedDescription)
            }
        }
    }
}
