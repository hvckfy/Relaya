import SwiftUI
import RelayaCore

/// Токены из docs/design (`.lt` / `.dk`). Каждый цвет меняется вместе с темой системы.
enum Theme {
    static let bg = dynamic(0xFFFFFF, 0x1E1E20)
    static let bg2 = dynamic(0xF5F5F7, 0x252527)
    static let side = dynamic(0xECECEF, 0x2A2A2D)
    static let bar = dynamic(0xF6F6F7, 0x2C2C2E)
    static let line = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.13)
    static let line2 = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    static let tx = dynamic(0x1D1D1F, 0xF5F5F7)
    static let tx2 = dynamic(0x5F5F64, 0xA8A8AE)
    static let acc = dynamic(0x0066CC, 0x5AA9FF)
    static let accBg = dynamic(0x0066CC, 0x0B6BD3)
    static let accTint = dynamic(0x0066CC, 0x5AA9FF, lightAlpha: 0.1, darkAlpha: 0.16)
    static let sel = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.1)
    static let red = dynamic(0xC4161C, 0xFF6B6B)
    static let org = dynamic(0xA84B00, 0xFFB347)
    static let orgTint = dynamic(0xA84B00, 0xFFB347, lightAlpha: 0.1, darkAlpha: 0.14)
    static let grn = dynamic(0x1B7A33, 0x5ED47A)
    static let grnTint = dynamic(0x1B7A33, 0x5ED47A, lightAlpha: 0.1, darkAlpha: 0.14)
    static let redTint = dynamic(0xC4161C, 0xFF6B6B, lightAlpha: 0.08, darkAlpha: 0.14)

    static let termBg = dynamicNS(0xFFFFFF, 0x161618)
    static let termTx = dynamicNS(0x1D1D1F, 0xE8E8EA)

    /// Палитра «Цвет хоста» из редактора.
    static let hostColors: [(name: String, label: String, color: Color)] = [
        ("blue", "Синий", Color(hex: 0x0A7AFF)),
        ("orange", "Оранжевый", Color(hex: 0xF08A00)),
        ("purple", "Фиолетовый", Color(hex: 0x8E4EC6)),
        ("gray", "Серый", Color(hex: 0x8E8E93)),
    ]

    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: dynamicNS(light, dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func dynamicNS(_ light: UInt32, _ dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension HostEnvironment {
    var color: Color {
        switch self {
        case .prod: Theme.red
        case .staging: Theme.org
        case .dev: Theme.grn
        }
    }

    var tint: Color {
        switch self {
        case .prod: Theme.redTint
        case .staging: Theme.orgTint
        case .dev: Theme.grnTint
        }
    }
}

/// Кнопки из макетов: `.btn`, `.btn.pri`, `.btn.ghost`.
struct RelayaButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, ghost }
    var kind: Kind = .normal
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height < 28 ? 12 : 13))
            .padding(.horizontal, height < 28 ? 8 : 12)
            .frame(height: height)
            .foregroundStyle(kind == .primary ? Color.white : kind == .ghost ? Theme.tx2 : Theme.tx)
            .background(background, in: .rect(cornerRadius: 6))
            .overlay {
                if kind == .normal { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 0.5) }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(.rect)
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accBg
        case .normal: Theme.bg
        case .ghost: .clear
        }
    }
}

extension ButtonStyle where Self == RelayaButtonStyle {
    static var relaya: RelayaButtonStyle { RelayaButtonStyle() }
    static var relayaPrimary: RelayaButtonStyle { RelayaButtonStyle(kind: .primary) }
    static func relaya(_ kind: RelayaButtonStyle.Kind, height: CGFloat = 28) -> RelayaButtonStyle {
        RelayaButtonStyle(kind: kind, height: height)
    }
}

/// Иконка-кнопка `.ib` из макетов.
struct IconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size < 24 ? 10 : 13, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.tx2)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct StatusDot: View {
    let connected: Bool

    var body: some View {
        Circle()
            .strokeBorder(connected ? Theme.grn : Theme.tx2, lineWidth: 1.5)
            .background(Circle().fill(connected ? Theme.grn : .clear))
            .frame(width: 8, height: 8)
            .accessibilityLabel(connected ? "подключён" : "не подключён")
    }
}
