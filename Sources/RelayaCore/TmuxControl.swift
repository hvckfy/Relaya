import Foundation

/// Протокол tmux control mode (`tmux -CC`): построчные уведомления от сервера и команды от клиента.
/// Окна tmux становятся вкладками Relaya, вывод панели — её терминалом. См. tmux(1), «CONTROL MODE».
public enum TmuxControl {
    public enum Event: Equatable, Sendable {
        /// Вывод панели `%N` (уже раскодированный).
        case output(pane: String, data: [UInt8])
        case windowAdd(window: String)
        case windowClose(window: String)
        case windowRenamed(window: String, name: String)
        /// Ответ на команду клиента: строки между `%begin` и `%end`/`%error`.
        case reply(lines: [String], error: Bool)
        case exit(reason: String?)
    }

    /// Разбор потока построчно; держит незавершённый ответ на команду между вызовами.
    public struct Parser: Sendable {
        private var buffer: [UInt8] = []
        private var reply: [String]?

        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [Event] {
            buffer += bytes
            var events: [Event] = []
            while let nl = buffer.firstIndex(of: 10) {
                var line = Array(buffer[..<nl])
                buffer.removeSubrange(...nl)
                if line.last == 13 { line.removeLast() }
                // DCS-заголовок `ESC P 1000 p`, с которого tmux начинает control mode.
                if let p = line.firstIndex(of: UInt8(ascii: "%")), line.first == 27 { line.removeSubrange(..<p) }
                if let e = parse(line) { events.append(e) }
            }
            return events
        }

        private mutating func parse(_ bytes: [UInt8]) -> Event? {
            let line = String(decoding: bytes, as: UTF8.self)
            if reply != nil {
                if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                    defer { reply = nil }
                    return .reply(lines: reply ?? [], error: line.hasPrefix("%error"))
                }
                reply?.append(line)
                return nil
            }
            if line.hasPrefix("%begin ") { reply = []; return nil }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch parts.first {
            case "%output" where parts.count >= 2:
                // Данные — после второго пробела, байты как есть, кроме \ooo и \\.
                let prefix = "%output \(parts[1]) ".utf8.count
                return .output(pane: parts[1], data: unescape(Array(bytes.dropFirst(prefix))))
            case "%window-add" where parts.count >= 2:
                return .windowAdd(window: parts[1])
            case "%window-close" where parts.count >= 2, "%unlinked-window-close" where parts.count >= 2:
                return .windowClose(window: parts[1])
            case "%window-renamed" where parts.count >= 3:
                return .windowRenamed(window: parts[1], name: parts[2])
            case "%exit":
                return .exit(reason: parts.count > 1 ? parts.dropFirst().joined(separator: " ") : nil)
            default:
                return nil
            }
        }
    }

    /// `\ooo` (восьмеричный байт) и `\\` → байты.
    public static func unescape(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            if s[i] == 92 {
                let d = s[(i + 1)...].prefix(3)
                if d.count == 3, d.allSatisfy({ $0 >= 48 && $0 <= 55 }) {
                    out.append(d.reduce(0) { $0 * 8 + ($1 - 48) })
                    i += 4
                    continue
                }
                if i + 1 < s.count, s[i + 1] == 92 { out.append(92); i += 2; continue }
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    // MARK: - Команды клиента (каждая — одна строка в stdin tmux)

    /// Ввод с клавиатуры в панель: байты в hex, чтобы не экранировать ничего.
    public static func sendKeys(pane: String, _ bytes: some Collection<UInt8>) -> String {
        "send-keys -t \(pane) -H " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Окна с их активной панелью: `@1 %3 name`.
    public static let listWindows = "list-windows -F '#{window_id} #{pane_id} #{window_name}'"

    public static func resize(window: String, cols: Int, rows: Int) -> String {
        "resize-window -t \(window) -x \(max(cols, 10)) -y \(max(rows, 3))"
    }

    /// Содержимое экрана панели с цветами — для первого показа.
    public static func capture(pane: String) -> String {
        "capture-pane -p -e -J -t \(pane)"
    }

    public static let newWindow = "new-window"

    public static func killWindow(_ window: String) -> String { "kill-window -t \(window)" }

    /// Разбор ответа `listWindows`.
    public static func parseWindows(_ lines: [String]) -> [(window: String, pane: String, name: String)] {
        lines.compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard f.count >= 2, f[0].hasPrefix("@"), f[1].hasPrefix("%") else { return nil }
            return (f[0], f[1], f.count > 2 ? f[2] : "")
        }
    }

    /// Команда для `ssh -tt host <cmd>` после `Tmux.prepareControlCommand`.
    public static func attachCommand(name: String) -> String {
        "tmux -CC attach-session -t \(name)"
    }
}
