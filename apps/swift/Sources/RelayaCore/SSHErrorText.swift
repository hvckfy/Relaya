import Foundation
import RelayaRust

/// Понятный текст ошибки ssh/sftp/git: «что случилось. что сделать» и исходная строка (ядро узнаёт ошибку,
/// перевод — здесь). Неизвестная ошибка — главная строка вывода (fatal:/error: или последняя).
public enum SSHErrorText {
    public static func describe(_ output: String, fallback: String? = nil) -> String {
        if let p = sshExplain(output: output) {
            return L(p.title) + ". " + L(p.hint) + "\n" + p.detail
        }
        let line = sshErrorLine(output: output)
        return line.isEmpty ? (fallback ?? output) : line
    }
}

/// Признак «вход выполнен, shell ждёт команду» по экрану терминала — логика ядра (C23), общая с Windows:
/// приглашение в строке курсора, курсор сразу после него, нет запросов пароля и ключа сервера.
public enum TerminalLogin {
    public static func ready(lines: [String], cursorRow: Int, cursorCol: Int, altScreen: Bool) -> Bool {
        terminalLoginReady(lines: lines, cursorRow: UInt32(max(0, cursorRow)), cursorCol: UInt32(max(0, cursorCol)), altScreen: altScreen)
    }
}
