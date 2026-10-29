import SwiftUI
import RelayaCore

/// Окно «Настройки» (⌘,): оформление и терминал.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Оформление", systemImage: "paintpalette") }
            HighlightSettings()
                .tabItem { Label("Подсветка", systemImage: "highlighter") }
            BehaviorSettings()
                .tabItem { Label("Подключения", systemImage: "bolt.horizontal") }
        }
        .frame(width: 640)
    }
}

private struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Тема приложения", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Цвета терминала", selection: $settings.terminalTheme) {
                ForEach(TerminalTheme.all) { Text($0.name).tag($0.id) }
            }

            Picker("Шрифт", selection: $settings.fontName) {
                ForEach(AppSettings.fontChoices, id: \.self) { Text($0).tag($0) }
            }

            LabeledContent("Размер") {
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
            Toggle("Option работает как Meta", isOn: $settings.optionAsMeta)
            Toggle("Переподключаться после обрыва соединения", isOn: $settings.autoReconnect)
            Toggle("Предлагать вход по ключу после входа по паролю", isOn: $settings.offerKeySetup)
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
                    RoundedRectangle(cornerRadius: 2).fill(ansi[i]).frame(width: 14, height: 10)
                }
            }
            .padding(.top, 4)
        }
        .font(Font(font))
        .foregroundColor(Color(nsColor: theme.foregroundColor))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: theme.backgroundColor), in: .rect(cornerRadius: 8))
    }
}

/// Правила подсветки вывода терминала.
private struct HighlightSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Подсвечивать вывод терминала", isOn: $settings.highlightEnabled)
                Text("Цвета берутся из палитры выбранной схемы терминала. Текст, который сервер уже раскрасил сам, и полноэкранные программы (vim, top, mc) не трогаются.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Правила — сверху вниз, первое совпадение важнее") {
                ForEach($settings.highlightRules) { $rule in
                    RuleRow(rule: $rule, palette: settings.theme.ansi) {
                        settings.highlightRules.removeAll { $0.id == rule.id }
                    }
                }
                .onMove { settings.highlightRules.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Button("Добавить правило") {
                        settings.highlightRules.append(HighlightRule(name: "Новое правило", pattern: "", isRegex: false, color: 12))
                    }
                    Spacer()
                    Button("Сбросить к стандартным") { settings.highlightRules = HighlightRule.defaults }
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
                TextField("Название", text: $rule.name)
                    .textFieldStyle(.plain)
                    .fontWeight(.medium)
                Spacer()
                Menu {
                    ForEach(0..<16, id: \.self) { i in
                        Button { rule.color = i } label: { Text(Self.colorNames[i]) }
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: palette[min(rule.color, palette.count - 1)]))
                        .frame(width: 22, height: 14)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Цвет: \(Self.colorNames[rule.color])")
                Toggle("Жирный", isOn: $rule.bold).toggleStyle(.checkbox)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Удалить правило")
            }
            HStack(spacing: 8) {
                TextField(rule.isRegex ? "Регулярное выражение" : "Текст", text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isValid ? Color.primary : Color.red)
                Toggle("Regex", isOn: $rule.isRegex).toggleStyle(.checkbox)
                Toggle("Aa", isOn: $rule.caseSensitive).toggleStyle(.checkbox).help("Учитывать регистр")
            }
            if !isValid {
                Text("Ошибка в регулярном выражении — правило не применяется").font(.system(size: 11)).foregroundStyle(.red)
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

    static let colorNames = ["Чёрный", "Красный", "Зелёный", "Жёлтый", "Синий", "Пурпурный", "Голубой", "Белый",
                             "Серый", "Ярко-красный", "Ярко-зелёный", "Ярко-жёлтый", "Ярко-синий",
                             "Ярко-пурпурный", "Ярко-голубой", "Ярко-белый"]
}
