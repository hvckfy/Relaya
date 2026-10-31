import Foundation
import RelayaRust

/// Протокол tmux control mode (`tmux -CC`): построчные уведомления от сервера и команды от клиента.
/// Окна tmux становятся вкладками Relaya, вывод панели — её терминалом. См. tmux(1), «CONTROL MODE».
public enum TmuxControl {
    public enum Event: Equatable, Sendable {
        /// Вывод панели `%N` (уже раскодированный).
        case output(pane: String, data: [UInt8])
        case windowAdd(window: String)
        case windowClose(window: String)
        case windowRenamed(window: String, name: String)
        /// В окне сменилась активная панель — вывод окна теперь идёт из неё.
        case windowPaneChanged(window: String, pane: String)
        /// Ответ на команду клиента: строки между `%begin` и `%end`/`%error`.
        case reply(lines: [String], error: Bool)
        case exit(reason: String?)
    }

    /// Разбор потока построчно; держит незавершённый ответ на команду между вызовами.
    /// Пошаговый разбор (Rust-ядро, `core/src/tmux_control.rs`): держит незавершённый ответ между вызовами.
    public struct Parser: @unchecked Sendable {
        private let parser = TmuxParser()
        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [Event] {
            parser.feed(bytes: Data(bytes)).map { e in
                switch e {
                case .output(let pane, let data): .output(pane: pane, data: [UInt8](data))
                case .windowAdd(let w): .windowAdd(window: w)
                case .windowClose(let w): .windowClose(window: w)
                case .windowRenamed(let w, let n): .windowRenamed(window: w, name: n)
                case .windowPaneChanged(let w, let p): .windowPaneChanged(window: w, pane: p)
                case .reply(let lines, let error): .reply(lines: lines, error: error)
                case .exit(let reason): .exit(reason: reason)
                }
            }
        }
    }

    /// `\ooo` (восьмеричный байт) и `\\` → байты.
    public static func unescape(_ s: [UInt8]) -> [UInt8] { [UInt8](tmuxCcUnescape(bytes: Data(s))) }

    /// Ввод с клавиатуры в панель: байты в hex.
    public static func sendKeys(pane: String, _ bytes: some Collection<UInt8>) -> String {
        tmuxCcSendKeys(pane: pane, bytes: Data(bytes))
    }

    public static var listWindows: String { tmuxCcListWindows() }

    public static func resize(window: String, cols: Int, rows: Int) -> String {
        tmuxCcResize(window: window, cols: Int64(cols), rows: Int64(rows))
    }

    public static func capture(pane: String) -> String { tmuxCcCapture(pane: pane) }

    public static let newWindow = "new-window"

    public static func killWindow(_ window: String) -> String { tmuxCcKillWindow(window: window) }

    public static func parseWindows(_ lines: [String]) -> [(window: String, pane: String, name: String)] {
        tmuxCcParseWindows(lines: lines).map { ($0.window, $0.pane, $0.name) }
    }

    public static func attachCommand(name: String) -> String { tmuxCcAttach(name: name) }
}
