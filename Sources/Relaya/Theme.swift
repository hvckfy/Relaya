import SwiftUI
import RelayaCore

/// Цвета интерфейса. Каждый токен — динамический NSColor: берёт значение из текущей
/// темы оформления (`ThemeStore.current`) и её светлого или тёмного варианта.
enum Theme {
    static let bg = token(\.bg)
    static let bg2 = token(\.bg2)
    static let side = token(\.side)
    /// Фон панелей сессий (файлы SFTP) поверх картинки фона.
    static let session = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let a = ThemeStore.sessionOpacity
        if ThemeStore.native { return NSColor(white: isDark ? 0.13 : 0.93, alpha: a) }
        let theme = ThemeStore.current
        return NSColor(hex: (isDark ? theme.dark : theme.light).bg, alpha: a)
    })

    /// Фон разделов в рабочей области: с картинкой фона — полупрозрачный.
    static let content = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let a = ThemeStore.contentOpacity
        if ThemeStore.native {
            return NSColor(white: isDark ? 0.13 : 0.93, alpha: a)
        }
        let theme = ThemeStore.current
        return NSColor(hex: (isDark ? theme.dark : theme.light).bg, alpha: a)
    })
    static let bar = token(\.bar)
    static let line = token(\.tx, light: 0.12, dark: 0.13)
    static let line2 = token(\.tx, light: 0.06, dark: 0.07)
    static let tx = token(\.tx)
    static let tx2 = token(\.tx2)
    static let acc = token(\.acc)
    static let accBg = token(\.accBg)
    static let accTint = token(\.acc, light: 0.1, dark: 0.16)
    static let sel = token(\.tx, light: 0.08, dark: 0.1)
    static let red = token(\.red)
    static let org = token(\.org)
    static let orgTint = token(\.org, light: 0.1, dark: 0.14)
    static let grn = token(\.grn)
    static let grnTint = token(\.grn, light: 0.1, dark: 0.14)
    static let redTint = token(\.red, light: 0.08, dark: 0.14)

    static let termBg = dynamicNS(0xFFFFFF, 0x161618)
    static let termTx = dynamicNS(0x1D1D1F, 0xE8E8EA)

    static func token(_ key: KeyPath<UIColors, UInt32> & Sendable, light: Double = 1, dark: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if ThemeStore.native, let system = systemColors[key] {
                return system.withAlphaComponent(isDark ? dark : light)
            }
            let theme = ThemeStore.current
            return NSColor(hex: (isDark ? theme.dark : theme.light)[keyPath: key], alpha: isDark ? dark : light)
        })
    }

    /// Системные цвета macOS для каждого токена — в нативном стиле окна.
    nonisolated(unsafe) private static let systemColors: [KeyPath<UIColors, UInt32>: NSColor] = [
        \.bg: .windowBackgroundColor, \.bg2: .controlBackgroundColor, \.side: .windowBackgroundColor,
        \.bar: .windowBackgroundColor, \.tx: .labelColor, \.tx2: .secondaryLabelColor,
        \.acc: .controlAccentColor, \.accBg: .controlAccentColor,
        \.red: .systemRed, \.org: .systemOrange, \.grn: .systemGreen,
    ]

    /// Палитра «Цвет хоста» из редактора.
    static let hostColors: [(name: String, label: String, color: Color)] = [
        ("blue", L("Синий"), Color(hex: 0x0A7AFF)),
        ("orange", L("Оранжевый"), Color(hex: 0xF08A00)),
        ("purple", L("Фиолетовый"), Color(hex: 0x8E4EC6)),
        ("gray", L("Серый"), Color(hex: 0x8E8E93)),
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

/// Цвет метки: привычные окружения узнаются по имени, остальные — стабильно по хэшу имени.
enum TagStyle {
    private static let palette: [Color] = [
        Color(hex: 0x0A7AFF), Color(hex: 0x8E4EC6), Color(hex: 0x0FA3A3),
        Color(hex: 0xD6457F), Color(hex: 0x6E6E73), Color(hex: 0x3A9E5C),
    ]

    static func color(_ tag: String) -> Color {
        switch tag.lowercased() {
        case "prod", "production", "прод": return Theme.red
        case "staging", "stage", "стейдж": return Theme.org
        case "dev", "test", "тест": return Theme.grn
        default:
            // Свой хэш: String.hashValue меняется между запусками.
            let h = tag.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7FFFFFFF }
            return palette[h % palette.count]
        }
    }
}

/// Метка-«пилюля».
struct TagChip: View {
    let tag: String
    var selected = true
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(TagStyle.color(tag)).frame(width: 6, height: 6)
            Text(tag).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tx2)
                .accessibilityLabel(L("Убрать метку %@", "\(tag)"))
            }
        }
        .font(.system(size: 11, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Theme.tx : Theme.tx2)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(selected ? TagStyle.color(tag).opacity(0.15) : .clear, in: .capsule)
        .overlay(Capsule().strokeBorder(selected ? TagStyle.color(tag).opacity(0.6) : Theme.line, lineWidth: 0.5))
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
            .background(background, in: shape)
            .overlay {
                if kind == .normal { shape.stroke(Theme.line, lineWidth: 0.5) }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(.rect)
    }

    /// По HIG: главные действия — капсула, обычные элементы управления — скруглённый прямоугольник.
    private var shape: AnyShape {
        kind == .primary ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: height < 28 ? 7 : 8, style: .continuous))
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accBg
        case .normal: Theme.bg
        case .ghost: .clear
        }
    }
}

/// В стиле Relaya — кнопки из макетов; в системном стиле — стандартные кнопки macOS.
struct AdaptiveButtonStyle: PrimitiveButtonStyle {
    var kind: RelayaButtonStyle.Kind = .normal
    var height: CGFloat = 28

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if ThemeStore.native {
            let size: ControlSize = height < 24 ? .mini : height < 28 ? .small : .regular
            switch kind {
            case .primary: Button(configuration).buttonStyle(.borderedProminent).controlSize(size)
            case .normal: Button(configuration).buttonStyle(.bordered).controlSize(size)
            case .ghost: Button(configuration).buttonStyle(.borderless).controlSize(size)
            }
        } else {
            Button(configuration).buttonStyle(RelayaButtonStyle(kind: kind, height: height))
        }
    }
}

extension PrimitiveButtonStyle where Self == AdaptiveButtonStyle {
    static var relaya: AdaptiveButtonStyle { AdaptiveButtonStyle() }
    static var relayaPrimary: AdaptiveButtonStyle { AdaptiveButtonStyle(kind: .primary) }
    static func relaya(_ kind: RelayaButtonStyle.Kind, height: CGFloat = 28) -> AdaptiveButtonStyle {
        AdaptiveButtonStyle(kind: kind, height: height)
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
            .accessibilityLabel(connected ? L("подключён") : L("не подключён"))
    }
}
