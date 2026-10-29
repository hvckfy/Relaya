import SwiftUI

/// Окно «Настройки» (⌘,): оформление и терминал.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Оформление", systemImage: "paintpalette") }
            BehaviorSettings()
                .tabItem { Label("Подключения", systemImage: "bolt.horizontal") }
        }
        .frame(width: 520)
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
