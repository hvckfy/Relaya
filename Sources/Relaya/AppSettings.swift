import SwiftUI
import SwiftTerm
import RelayaCore

/// Пользовательские настройки (окно Settings). Хранятся в UserDefaults.
@MainActor
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: L("Системная")
            case .light: L("Светлая")
            case .dark: L("Тёмная")
            }
        }
    }

    private let defaults = UserDefaults.standard

    /// Тема оформления интерфейса (встроенная или своя).
    var uiThemeID: String {
        didSet { defaults.set(uiThemeID, forKey: "uiTheme"); applyUITheme() }
    }
    /// Вид блока «Состояние» в карточке хоста.
    enum StatsStyle: String, CaseIterable, Identifiable {
        case tiles, compact, pixel, console
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tiles: L("Плитки")
            case .compact: L("Компактный")
            case .pixel: L("Пиксельный")
            case .console: L("Консоль")
            }
        }
    }
    var statsStyle: StatsStyle {
        didSet { defaults.set(statsStyle.rawValue, forKey: "statsStyle") }
    }

    /// Картинка фона рабочей области: одна на всё окно, плитки и панели просвечивают.
    var backgroundImagePath: String? {
        didSet { defaults.set(backgroundImagePath, forKey: "backgroundImagePath"); applyBackground() }
    }
    /// Показывать картинку под терминалами и файлами.
    var backgroundUnderSessions: Bool {
        didSet { defaults.set(backgroundUnderSessions, forKey: "backgroundUnderSessions"); applyBackground() }
    }
    /// Показывать картинку под карточками и разделами (хост, ключи, туннели…).
    var backgroundUnderInterface: Bool {
        didSet { defaults.set(backgroundUnderInterface, forKey: "backgroundUnderInterface"); applyBackground() }
    }
    /// Непрозрачность терминалов и панелей поверх картинки: 0.2 — почти прозрачно, 1 — картинки не видно.
    var backgroundPanelOpacity: Double {
        didSet { defaults.set(backgroundPanelOpacity, forKey: "backgroundPanelOpacity"); applyBackground() }
    }

    var backgroundImage: NSImage? { backgroundImagePath.flatMap { NSImage(contentsOfFile: $0) } }

    func applyBackground() {
        let on = backgroundImagePath != nil
        ThemeStore.contentOpacity = on && backgroundUnderInterface ? backgroundPanelOpacity : 1
        ThemeStore.sessionOpacity = on && backgroundUnderSessions ? backgroundPanelOpacity : 1
        themeRevision += 1
    }

    /// Liquid Glass на вкладках и панелях (macOS 26 и новее).
    var liquidGlass: Bool {
        didSet { defaults.set(liquidGlass, forKey: "liquidGlass"); ThemeStore.glass = liquidGlass; themeRevision += 1 }
    }
    static var liquidGlassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Стиль окна: false — Relaya (темы оформления), true — системный macOS.
    var nativeUI: Bool {
        didSet { defaults.set(nativeUI, forKey: "nativeUI"); ThemeStore.native = nativeUI; themeRevision += 1 }
    }
    var customThemes: [UITheme] {
        didSet {
            defaults.set(try? JSONEncoder().encode(customThemes), forKey: "customThemes")
            applyUITheme()
        }
    }
    /// Меняется при любой правке темы — корневые view перерисовываются по нему.
    private(set) var themeRevision = 0

    var allUIThemes: [UITheme] { UITheme.builtIns + customThemes }
    var uiTheme: UITheme { allUIThemes.first { $0.id == uiThemeID } ?? .relaya }

    func applyUITheme() {
        ThemeStore.current = uiTheme
        themeRevision += 1
    }

    /// Новая своя тема — копия текущей.
    func duplicateCurrentTheme() {
        var copy = uiTheme
        copy.id = "custom-" + UUID().uuidString
        copy.name = uiTheme.name + L(" (копия)")
        copy.builtIn = false
        customThemes.append(copy)
        uiThemeID = copy.id
    }

    func deleteCustomTheme(_ id: String) {
        customThemes.removeAll { $0.id == id }
        if uiThemeID == id { uiThemeID = UITheme.relaya.id }
    }

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
    /// Через сколько минут без подключения сервер сам закрывает сессию tmux.
    var tmuxIdleMinutes: Int {
        didSet { defaults.set(tmuxIdleMinutes, forKey: "tmuxIdleMinutes") }
    }
    var menuBarIcon: Bool {
        didSet { if menuBarIcon != oldValue { defaults.set(menuBarIcon, forKey: "menuBarIcon") } }
    }
    var offerKeySetup: Bool {
        didSet { defaults.set(offerKeySetup, forKey: "offerKeySetup") }
    }
    var highlightEnabled: Bool {
        didSet { defaults.set(highlightEnabled, forKey: "highlightEnabled") }
    }
    var highlightRules: [HighlightRule] {
        didSet { defaults.set(try? JSONEncoder().encode(highlightRules), forKey: "highlightRules") }
    }

    init() {
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        uiThemeID = defaults.string(forKey: "uiTheme") ?? UITheme.relaya.id
        statsStyle = StatsStyle(rawValue: defaults.string(forKey: "statsStyle") ?? "") ?? .tiles
        let imagePath = defaults.string(forKey: "backgroundImagePath")
        let underSessions = defaults.object(forKey: "backgroundUnderSessions") as? Bool ?? true
        let underInterface = defaults.object(forKey: "backgroundUnderInterface") as? Bool ?? true
        let panelOpacity = defaults.object(forKey: "backgroundPanelOpacity") as? Double ?? 0.75
        backgroundImagePath = imagePath
        backgroundUnderSessions = underSessions
        backgroundUnderInterface = underInterface
        backgroundPanelOpacity = panelOpacity
        let glass = defaults.bool(forKey: "liquidGlass")
        liquidGlass = glass
        ThemeStore.glass = glass
        let native = defaults.bool(forKey: "nativeUI")
        nativeUI = native
        ThemeStore.native = native
        ThemeStore.contentOpacity = imagePath != nil && underInterface ? panelOpacity : 1
        ThemeStore.sessionOpacity = imagePath != nil && underSessions ? panelOpacity : 1
        customThemes = defaults.data(forKey: "customThemes")
            .flatMap { try? JSONDecoder().decode([UITheme].self, from: $0) } ?? []
        terminalTheme = defaults.string(forKey: "terminalTheme") ?? TerminalTheme.relayaDark.id
        fontName = defaults.string(forKey: "fontName") ?? "SF Mono"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 12.5
        optionAsMeta = defaults.object(forKey: "optionAsMeta") as? Bool ?? true
        autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        offerKeySetup = defaults.object(forKey: "offerKeySetup") as? Bool ?? true
        tmuxIdleMinutes = defaults.object(forKey: "tmuxIdleMinutes") as? Int ?? 60
        menuBarIcon = defaults.object(forKey: "menuBarIcon") as? Bool ?? true
        highlightEnabled = defaults.object(forKey: "highlightEnabled") as? Bool ?? true
        highlightRules = defaults.data(forKey: "highlightRules")
            .flatMap { try? JSONDecoder().decode([HighlightRule].self, from: $0) } ?? HighlightRule.defaults
        ThemeStore.current = uiTheme
    }

    /// Язык интерфейса. macOS читает его при запуске, поэтому смена требует перезапуска.
    enum Language: String, CaseIterable, Identifiable {
        case system, ru, en
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: L("Системный")
            case .ru: "Русский"
            case .en: "English"
            }
        }
    }

    var language: Language {
        get { Language(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appLanguage")
            // AppleLanguages в домене приложения — стандартный способ задать язык одному приложению.
            if newValue == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([newValue.rawValue], forKey: "AppleLanguages")
            }
            languageChanged = true
        }
    }
    /// Счётчик для перерисовки настроек, которые читаются прямо из UserDefaults.
    private(set) var revision = 0
    func touch() { revision += 1 }

    /// Язык сменили в этом запуске — показать «Перезапустить».
    var languageChanged = false

    /// Перезапуск приложения: новая копия откроется через секунду, эта закроется.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var theme: TerminalTheme { TerminalTheme.all.first { $0.id == terminalTheme } ?? .relayaDark }

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
        id: "relaya", name: L("По теме системы"), background: nil, foreground: nil,
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

    static let relayaDark = TerminalTheme(
        id: "relaya-dark", name: "Relaya Dark", background: 0x16181D, foreground: 0xD8DEE9,
        ansi: [0x2A2E37, 0xF0616D, 0x7FD18B, 0xF5C76B, 0x5AA9FF, 0xC792EA, 0x5FD7D7, 0xC8CDD6,
               0x5C6370, 0xFF7B86, 0x9BE6A6, 0xFFD88A, 0x82BFFF, 0xDDB2F5, 0x8AE8E8, 0xFFFFFF])
    static let relayaLight = TerminalTheme(
        id: "relaya-light", name: "Relaya Light", background: 0xFBFBFC, foreground: 0x24292F,
        ansi: [0x24292F, 0xC4161C, 0x1B7A33, 0x9A5B00, 0x0066CC, 0x8E4EC6, 0x0F7B7B, 0x6E7781,
               0x57606A, 0xD9363E, 0x2A9147, 0xB57A00, 0x2F81F7, 0xA371F7, 0x1A9C9C, 0x8C959F])
    static let nord = TerminalTheme(
        id: "nord", name: "Nord", background: 0x2E3440, foreground: 0xD8DEE9,
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])
    static let gruvbox = TerminalTheme(
        id: "gruvbox-dark", name: "Gruvbox Dark", background: 0x282828, foreground: 0xEBDBB2,
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2])
    static let monokai = TerminalTheme(
        id: "monokai", name: "Monokai", background: 0x272822, foreground: 0xF8F8F2,
        ansi: [0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
               0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5])
    static let tomorrowNight = TerminalTheme(
        id: "tomorrow-night", name: "Tomorrow Night", background: 0x1D1F21, foreground: 0xC5C8C6,
        ansi: [0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
               0x969896, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xFFFFFF])

    static let all = [relayaDark, relayaLight, relaya, nord, gruvbox, monokai, tomorrowNight,
                      oneDark, dracula, solarizedDark, solarizedLight]

    var backgroundColor: NSColor { background.map { NSColor(hex: $0) } ?? Theme.termBg }
    var foregroundColor: NSColor { foreground.map { NSColor(hex: $0) } ?? Theme.termTx }

    var ansiColors: [SwiftTerm.Color] {
        ansi.map { hex in
            func c(_ shift: UInt32) -> UInt16 { UInt16((hex >> shift) & 0xFF) * 257 }
            return SwiftTerm.Color(red: c(16), green: c(8), blue: c(0))
        }
    }
}
