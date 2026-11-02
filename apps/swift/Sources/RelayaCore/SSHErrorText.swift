import Foundation
import RelayaRust

/// Понятный текст ошибки ssh/sftp/git: «что случилось. что сделать» и исходная строка (ядро узнаёт ошибку,
/// перевод — здесь). Неизвестная ошибка — главная строка вывода (fatal:/error: или последняя).
public enum SSHErrorText {
    /// The server refused the login or cut the connection before it (rules in the core): callers stop retrying
    /// with the same credentials and wait for the user.
    public static func loginRefused(_ output: String) -> Bool {
        sshAuthRefused(output: output) || sshBlocked(output: output)
    }

    /// The server cut the connection before login (a ban, MaxStartups, sshd still starting), with no refusal of
    /// the credentials themselves.
    public static func loginBlocked(_ output: String) -> Bool {
        sshBlocked(output: output) && !sshAuthRefused(output: output)
    }

    public enum RemoteKind: Sendable { case rdp, vnc }

    /// Понятная ошибка RDP/VNC (ядро узнаёт текст RDPKit/RoyalVNC и др.): «что случилось. что сделать» и исходный текст.
    public static func describeRemote(_ kind: RemoteKind, _ message: String) -> String {
        if let p = remoteExplain(protocol: kind == .rdp ? .rdp : .vnc, message: message) {
            return L(p.title) + ". " + L(p.hint) + (p.detail.isEmpty ? "" : "\n" + p.detail)
        }
        return message
    }

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
