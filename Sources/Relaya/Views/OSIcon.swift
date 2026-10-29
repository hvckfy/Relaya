import SwiftUI
import RelayaCore

/// Значок ОС сервера: SF Symbol, где он есть, иначе бейдж в фирменном цвете дистрибутива.
struct OSIcon: View {
    let os: ServerOS?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let os {
                switch os.style {
                case .symbol(let name, let color):
                    Image(systemName: name)
                        .font(.system(size: size * 0.72, weight: .semibold))
                        .foregroundStyle(color)
                case .badge(let text, let color):
                    Text(text)
                        .font(.system(size: size * (text.count > 1 ? 0.42 : 0.56), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .frame(width: size, height: size)
                        .background(color, in: .rect(cornerRadius: size * 0.28))
                }
            } else {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .foregroundStyle(Theme.tx2)
            }
        }
        .frame(width: size, height: size)
        .help(os?.title ?? "ОС ещё не определена")
        .accessibilityLabel(os?.title ?? "ОС не определена")
    }
}

extension ServerOS {
    enum Style {
        case symbol(String, Color)
        case badge(String, Color)
    }

    var style: Style {
        switch self {
        case .macos: .symbol("apple.logo", Theme.tx)
        case .openwrt: .symbol("wifi.router", Color(hex: 0x00B5E2))
        case .windows: .symbol("pc", Color(hex: 0x0078D4))
        case .linux: .symbol("terminal", Theme.tx2)
        case .ubuntu: .badge("U", Color(hex: 0xE95420))
        case .debian: .badge("D", Color(hex: 0xA81D33))
        case .raspbian: .badge("Pi", Color(hex: 0xC51A4A))
        case .fedora: .badge("F", Color(hex: 0x51A2DA))
        case .centos: .badge("C", Color(hex: 0x932279))
        case .rhel: .badge("RH", Color(hex: 0xCC0000))
        case .rocky: .badge("R", Color(hex: 0x10B981))
        case .alma: .badge("A", Color(hex: 0x0F4266))
        case .alpine: .badge("A", Color(hex: 0x0D597F))
        case .arch: .badge("A", Color(hex: 0x1793D1))
        case .opensuse: .badge("S", Color(hex: 0x73BA25))
        case .freebsd: .badge("BSD", Color(hex: 0xAB2B28))
        }
    }
}

/// Меню «Действия» для ОС сервера: команда вставляется в терминал без Enter.
struct OSActionsMenu: View {
    let os: ServerOS?
    let user: String?
    let insert: (String) -> Void

    var body: some View {
        Menu {
            if let os {
                Section(os.title) {
                    ForEach(os.actions, id: \.self) { action in
                        Button(action.title) { insert(command(for: action)) }
                    }
                }
            } else {
                Text("ОС ещё не определена")
            }
        } label: {
            Text("Действия")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Команда вставится в терминал — проверьте её и нажмите Enter")
    }

    /// Под root `sudo` не нужен (и его может не быть, как на OpenWrt).
    private func command(for action: OSAction) -> String {
        guard user == "root" else { return action.command }
        return action.command.replacingOccurrences(of: "sudo ", with: "")
    }
}
