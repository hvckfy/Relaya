import SwiftUI
import RelayaCore

/// Окно «Настройки» (⌘,): оформление и терминал.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label(L("Оформление"), systemImage: "paintpalette") }
            HighlightSettings()
                .tabItem { Label(L("Подсветка"), systemImage: "highlighter") }
            BehaviorSettings()
                .tabItem { Label(L("Подключения"), systemImage: "bolt.horizontal") }
        }
        .frame(width: 640)
    }
}

private struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker(L("Режим"), selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Section(L("Оформление интерфейса")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(settings.allUIThemes) { theme in
                        ThemeCard(theme: theme, selected: theme.id == settings.uiThemeID)
                            .onTapGesture { settings.uiThemeID = theme.id }
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    Button(L("Создать свою на основе «%@»", "\(settings.uiTheme.name)")) { settings.duplicateCurrentTheme() }
                    Spacer()
                    if !settings.uiTheme.builtIn {
                        Button(L("Удалить тему"), role: .destructive) { settings.deleteCustomTheme(settings.uiThemeID) }
                    }
                }
                if let index = settings.customThemes.firstIndex(where: { $0.id == settings.uiThemeID }) {
                    CustomThemeEditor(theme: $settings.customThemes[index])
                }
            }

            Picker(L("Цвета терминала"), selection: $settings.terminalTheme) {
                ForEach(TerminalTheme.all) { Text($0.name).tag($0.id) }
            }

            Picker(L("Шрифт"), selection: $settings.fontName) {
                ForEach(AppSettings.fontChoices, id: \.self) { Text($0).tag($0) }
            }

            LabeledContent(L("Размер")) {
                HStack {
                    Slider(value: $settings.fontSize, in: 9...24, step: 0.5)
                    Text(String(format: "%.1f pt", settings.fontSize))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }

            ThemePreview(theme: settings.theme, font: settings.font)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct BehaviorSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker(L("Язык"), selection: $settings.language) {
                ForEach(AppSettings.Language.allCases) { Text($0.title).tag($0) }
            }
            if settings.languageChanged {
                HStack {
                    Text(L("Язык сменится после перезапуска Relaya.")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Перезапустить сейчас")) { settings.relaunch() }
                }
            }
            Toggle(L("Option работает как Meta"), isOn: $settings.optionAsMeta)
            Toggle(L("Переподключаться после обрыва соединения"), isOn: $settings.autoReconnect)
            Toggle(L("Предлагать вход по ключу после входа по паролю"), isOn: $settings.offerKeySetup)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

/// Пример вывода терминала в выбранной схеме.
private struct ThemePreview: View {
    let theme: TerminalTheme
    let font: NSFont

    var body: some View {
        let ansi = theme.ansi.map { Color(hex: $0) }
        VStack(alignment: .leading, spacing: 2) {
            (Text("ubuntu@web").foregroundColor(ansi[2]) + Text(":") + Text("~").foregroundColor(ansi[4]) + Text("$ ls"))
            (Text("deploy  ").foregroundColor(ansi[4]) + Text("logs  ") + Text("run.sh").foregroundColor(ansi[2]))
            Text("error: disk 91% full").foregroundColor(ansi[1])
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ansi[i]).frame(width: 14, height: 10)
                }
            }
            .padding(.top, 4)
        }
        .font(Font(font))
        .foregroundColor(Color(nsColor: theme.foregroundColor))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: theme.backgroundColor), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Правила подсветки вывода терминала.
private struct HighlightSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(L("Подсвечивать вывод терминала"), isOn: $settings.highlightEnabled)
                Text(L("Цвета берутся из палитры выбранной схемы терминала. Текст, который сервер уже раскрасил сам, и полноэкранные программы (vim, top, mc) не трогаются."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section(L("Правила — сверху вниз, первое совпадение важнее")) {
                ForEach($settings.highlightRules) { $rule in
                    RuleRow(rule: $rule, palette: settings.theme.ansi) {
                        settings.highlightRules.removeAll { $0.id == rule.id }
                    }
                }
                .onMove { settings.highlightRules.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Button(L("Добавить правило")) {
                        settings.highlightRules.append(HighlightRule(name: L("Новое правило"), pattern: "", isRegex: false, color: 12))
                    }
                    Spacer()
                    Button(L("Сбросить к стандартным")) { settings.highlightRules = HighlightRule.defaults }
                }
            }
            .disabled(!settings.highlightEnabled)
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .padding(.vertical, 8)
    }
}

private struct RuleRow: View {
    @Binding var rule: HighlightRule
    let palette: [UInt32]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: $rule.enabled).labelsHidden()
                TextField(L("Название"), text: $rule.name)
                    .textFieldStyle(.plain)
                    .fontWeight(.medium)
                Spacer()
                Menu {
                    ForEach(0..<16, id: \.self) { i in
                        Button { rule.color = i } label: { Text(Self.colorNames[i]) }
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(hex: palette[min(rule.color, palette.count - 1)]))
                        .frame(width: 22, height: 14)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Цвет: %@", "\(Self.colorNames[rule.color])"))
                Toggle(L("Жирный"), isOn: $rule.bold).toggleStyle(.checkbox)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L("Удалить правило"))
            }
            HStack(spacing: 8) {
                TextField(rule.isRegex ? L("Регулярное выражение") : L("Текст"), text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isValid ? Color.primary : Color.red)
                Toggle("Regex", isOn: $rule.isRegex).toggleStyle(.checkbox)
                Toggle("Aa", isOn: $rule.caseSensitive).toggleStyle(.checkbox).help(L("Учитывать регистр"))
            }
            if !isValid {
                Text(L("Ошибка в регулярном выражении — правило не применяется")).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .opacity(rule.enabled ? 1 : 0.55)
        .padding(.vertical, 2)
    }

    private var isValid: Bool {
        var probe = rule
        probe.enabled = true
        return rule.pattern.isEmpty || probe.compiled() != nil
    }

    static let colorNames = [L("Чёрный"), L("Красный"), L("Зелёный"), L("Жёлтый"), L("Синий"), L("Пурпурный"), L("Голубой"), L("Белый"),
                             L("Серый"), L("Ярко-красный"), L("Ярко-зелёный"), L("Ярко-жёлтый"), L("Ярко-синий"),
                             L("Ярко-пурпурный"), L("Ярко-голубой"), L("Ярко-белый")]
}

/// Карточка темы: мини-окно в светлом и тёмном варианте.
private struct ThemeCard: View {
    let theme: UITheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                mini(theme.light)
                mini(theme.dark)
            }
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            Text(theme.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(.rect)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(theme.name)
    }

    private func mini(_ c: UIColors) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(hex: c.side)).frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Rectangle().fill(Color(hex: c.bar)).frame(height: 8)
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Color(hex: c.tx)).frame(width: 22, height: 3).padding(.leading, 4)
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Color(hex: c.tx2)).frame(width: 16, height: 3).padding(.leading, 4)
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color(hex: c.accBg)).frame(width: 18, height: 7).padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .background(Color(hex: c.bg))
        }
        .frame(height: 44)
    }
}

/// Редактор своей темы: имя и цвета для светлого и тёмного режима.
private struct CustomThemeEditor: View {
    @Binding var theme: UITheme

    var body: some View {
        TextField(L("Название"), text: $theme.name)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("")
                Text(L("Светлая")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(L("Тёмная")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            ForEach(UIColors.fields, id: \.label) { field in
                GridRow {
                    Text(field.label)
                    ColorPicker("", selection: binding(\.light, field.key), supportsOpacity: false).labelsHidden()
                    ColorPicker("", selection: binding(\.dark, field.key), supportsOpacity: false).labelsHidden()
                }
            }
        }
    }

    private func binding(_ mode: WritableKeyPath<UITheme, UIColors>, _ key: WritableKeyPath<UIColors, UInt32>) -> Binding<Color> {
        Binding(
            get: { Color(hex: theme[keyPath: mode][keyPath: key]) },
            set: { theme[keyPath: mode][keyPath: key] = NSColor($0).hexValue }
        )
    }
}

private extension NSColor {
    var hexValue: UInt32 {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return b(c.redComponent) << 16 | b(c.greenComponent) << 8 | b(c.blueComponent)
    }
}
