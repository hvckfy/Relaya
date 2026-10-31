import SwiftUI
import SwiftTerm
import RelayaCore

/// Вкладка с окном tmux (control mode): терминал без своего процесса, данные — через соединение tmux.
struct TmuxPaneContent: View {
    @Environment(AppSettings.self) private var settings
    let window: TmuxWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").foregroundStyle(Theme.tx2)
                Text("tmux · \(window.client.sessionName) · \(window.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tx2)
                Spacer()
                Button(L("Новое окно")) { window.client.newWindow() }
                    .buttonStyle(.relaya(.ghost, height: 20))
                Button(L("Отключиться")) { window.client.detach() }
                    .buttonStyle(.relaya(.ghost, height: 20))
                    .help(L("Сессия останется на сервере; её закроет таймер, если не вернуться"))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            TmuxPaneRepresentable(window: window)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: settings.theme.backgroundColor.withAlphaComponent(ThemeStore.sessionOpacity)))
        }
    }
}

private struct TmuxPaneRepresentable: NSViewRepresentable {
    @Environment(AppSettings.self) private var settings
    let window: TmuxWindow

    func makeNSView(context: Context) -> TmuxPaneView {
        let v = window.makeView()
        apply(v)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: TmuxPaneView, context: Context) { apply(v) }

    private func apply(_ v: TmuxPaneView) {
        let theme = settings.theme
        if v.font != settings.font { v.font = settings.font }
        v.nativeBackgroundColor = theme.backgroundColor.withAlphaComponent(ThemeStore.sessionOpacity)
        v.nativeForegroundColor = theme.foregroundColor
        v.caretColor = theme.foregroundColor
        v.optionAsMetaKey = settings.optionAsMeta
        v.installColors(theme.ansiColors)
    }
}
