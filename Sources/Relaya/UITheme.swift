import Foundation

/// Набор цветов интерфейса для одного режима (светлого или тёмного).
struct UIColors: Codable, Hashable, Sendable {
    var bg: UInt32
    var bg2: UInt32
    var side: UInt32
    var bar: UInt32
    var tx: UInt32
    var tx2: UInt32
    var acc: UInt32
    var accBg: UInt32
    var red: UInt32
    var org: UInt32
    var grn: UInt32

    /// Поля для редактора своей темы.
    nonisolated(unsafe) static let fields: [(key: WritableKeyPath<UIColors, UInt32>, label: String)] = [
        (\.bg, "Фон"), (\.bg2, "Карточки"), (\.side, "Боковая панель"), (\.bar, "Тулбар и вкладки"),
        (\.tx, "Текст"), (\.tx2, "Второстепенный текст"), (\.acc, "Акцент"), (\.accBg, "Кнопки"),
        (\.red, "Ошибка"), (\.org, "Предупреждение"), (\.grn, "Успех"),
    ]
}

/// Тема оформления интерфейса. Встроенные — в коде, свои — в UserDefaults.
struct UITheme: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var light: UIColors
    var dark: UIColors
    var builtIn = false

    private static func pair(_ l: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
                             _ d: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
                             status: (light: (UInt32, UInt32, UInt32), dark: (UInt32, UInt32, UInt32))
                                = ((0xC4161C, 0xA84B00, 0x1B7A33), (0xFF6B6B, 0xFFB347, 0x5ED47A)))
        -> (UIColors, UIColors) {
        (UIColors(bg: l.0, bg2: l.1, side: l.2, bar: l.3, tx: l.4, tx2: l.5, acc: l.6, accBg: l.7,
                  red: status.light.0, org: status.light.1, grn: status.light.2),
         UIColors(bg: d.0, bg2: d.1, side: d.2, bar: d.3, tx: d.4, tx2: d.5, acc: d.6, accBg: d.7,
                  red: status.dark.0, org: status.dark.1, grn: status.dark.2))
    }

    private static func make(_ id: String, _ name: String, _ p: (UIColors, UIColors)) -> UITheme {
        UITheme(id: id, name: name, light: p.0, dark: p.1, builtIn: true)
    }

    static let relaya = make("relaya", "Relaya", pair(
        (0xFFFFFF, 0xF5F5F7, 0xECECEF, 0xF6F6F7, 0x1D1D1F, 0x5F5F64, 0x0066CC, 0x0066CC),
        (0x1E1E20, 0x252527, 0x2A2A2D, 0x2C2C2E, 0xF5F5F7, 0xA8A8AE, 0x5AA9FF, 0x0B6BD3)))
    static let graphite = make("graphite", "Graphite", pair(
        (0xFFFFFF, 0xF4F4F5, 0xE9E9EB, 0xF3F3F4, 0x1C1C1E, 0x636366, 0x545A66, 0x3A3F4A),
        (0x1C1C1E, 0x242426, 0x262628, 0x2A2A2C, 0xF2F2F7, 0x9A9AA0, 0xA8B0BF, 0x4A5160)))
    static let ocean = make("ocean", "Ocean", pair(
        (0xF7FBFF, 0xEEF5FC, 0xE1EDF8, 0xEAF2FA, 0x0F2236, 0x4E6378, 0x0A6EBD, 0x0A6EBD),
        (0x0E1A26, 0x13212F, 0x112130, 0x152637, 0xE6F0FA, 0x8FA6BC, 0x5DB2FF, 0x1A73C8)))
    static let forest = make("forest", "Forest", pair(
        (0xFBFCFA, 0xF1F5EF, 0xE4ECE1, 0xEEF3EC, 0x17251A, 0x55665A, 0x2E7D4F, 0x2E7D4F),
        (0x141A16, 0x19211C, 0x1B241E, 0x1F2922, 0xE8F0EA, 0x93A598, 0x6FCF97, 0x2E7D4F)))
    static let sunset = make("sunset", "Sunset", pair(
        (0xFFFBF7, 0xFBF2EA, 0xF5E6D9, 0xF9EEE4, 0x2B1B12, 0x6E5646, 0xC2571A, 0xC2571A),
        (0x1D1612, 0x241C17, 0x281F19, 0x2C221C, 0xF7ECE4, 0xB39C8C, 0xFF9A5C, 0xC2571A)))
    static let nord = make("nord", "Nord", pair(
        (0xECEFF4, 0xE5E9F0, 0xD8DEE9, 0xE5E9F0, 0x2E3440, 0x4C566A, 0x5E81AC, 0x5E81AC),
        (0x2E3440, 0x3B4252, 0x353C4A, 0x3B4252, 0xECEFF4, 0xA3ABB9, 0x88C0D0, 0x5E81AC),
        status: ((0xBF616A, 0xD08770, 0x5E8C4A), (0xBF616A, 0xD08770, 0xA3BE8C))))

    static let builtIns = [relaya, graphite, ocean, forest, sunset, nord]
}

/// Текущая тема. Читается динамическими цветами при отрисовке, поэтому без изоляции актора;
/// меняется только из AppSettings на главном потоке.
enum ThemeStore {
    nonisolated(unsafe) static var current: UITheme = .relaya
}
