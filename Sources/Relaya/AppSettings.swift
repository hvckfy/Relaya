import SwiftUI
import SwiftTerm

/// Пользовательские настройки (окно Settings). Хранятся в UserDefaults.
@MainActor
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Системная"
            case .light: "Светлая"
            case .dark: "Тёмная"
            }
        }
    }

    private let defaults = UserDefaults.standard

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance"); applyAppearance() }
    }
    var terminalTheme: TerminalTheme.ID {
        didSet { defaults.set(terminalTheme, forKey: "terminalTheme") }
    }
    var fontName: String {
        didSet { defaults.set(fontName, forKey: "fontName") }
    }
    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "fontSize") }
    }
    var optionAsMeta: Bool {
        didSet { defaults.set(optionAsMeta, forKey: "optionAsMeta") }
    }
    var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: "autoReconnect") }
    }
    var offerKeySetup: Bool {
        didSet { defaults.set(offerKeySetup, forKey: "offerKeySetup") }
    }

    init() {
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        terminalTheme = defaults.string(forKey: "terminalTheme") ?? TerminalTheme.relaya.id
        fontName = defaults.string(forKey: "fontName") ?? "SF Mono"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 12.5
        optionAsMeta = defaults.object(forKey: "optionAsMeta") as? Bool ?? true
        autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        offerKeySetup = defaults.object(forKey: "offerKeySetup") as? Bool ?? true
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var theme: TerminalTheme { TerminalTheme.all.first { $0.id == terminalTheme } ?? .relaya }

    var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static let fontChoices = ["SF Mono", "Menlo", "Monaco", "Courier New", "JetBrains Mono", "Fira Code"]
        .filter { NSFont(name: $0, size: 12) != nil }
}

/// Цветовая схема терминала. `nil`-цвета — берутся из темы приложения (светлая/тёмная).
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: UInt32?
    let foreground: UInt32?
    /// 16 цветов ANSI (8 обычных + 8 ярких).
    let ansi: [UInt32]

    static let relaya = TerminalTheme(
        id: "relaya", name: "Relaya (по теме системы)", background: nil, foreground: nil,
        ansi: [0x1D1D1F, 0xC4161C, 0x1B7A33, 0xA84B00, 0x0066CC, 0x8E4EC6, 0x0F8A8A, 0xBFBFC4,
               0x5F5F64, 0xFF6B6B, 0x5ED47A, 0xFFB347, 0x5AA9FF, 0xB98AE6, 0x4FD1D1, 0xF5F5F7])
    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", background: 0x002B36, foreground: 0x839496,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])
    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", background: 0xFDF6E3, foreground: 0x657B83,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])
    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", background: 0x282A36, foreground: 0xF8F8F2,
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])
    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark", background: 0x282C34, foreground: 0xABB2BF,
        ansi: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF])

    static let all = [relaya, solarizedDark, solarizedLight, dracula, oneDark]

    var backgroundColor: NSColor { background.map { NSColor(hex: $0) } ?? Theme.termBg }
    var foregroundColor: NSColor { foreground.map { NSColor(hex: $0) } ?? Theme.termTx }

    var ansiColors: [SwiftTerm.Color] {
        ansi.map { hex in
            func c(_ shift: UInt32) -> UInt16 { UInt16((hex >> shift) & 0xFF) * 257 }
            return SwiftTerm.Color(red: c(16), green: c(8), blue: c(0))
        }
    }
}
