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
