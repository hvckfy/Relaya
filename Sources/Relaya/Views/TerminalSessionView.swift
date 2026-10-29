import SwiftUI
import SwiftTerm
import RelayaCore

/// Вкладки сессий (34 pt, как в макете Main).
struct SessionTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.sessions) { session in
                        SessionTab(session: session, active: session.id == model.activeSessionID)
                    }
                }
            }
            IconButton(systemImage: "plus", label: "Новая вкладка", size: 34) {
                if let host = model.activeSession?.host ?? model.selectedHost { model.connect(host) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 34)
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

private struct SessionTab: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.host.tags.first.map(TagStyle.color) ?? Theme.tx2)
                .frame(width: 7, height: 7)
            Text(session.host.alias)
                .fontWeight(active ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 4)
            IconButton(systemImage: "xmark", label: "Закрыть вкладку \(session.host.alias)", size: 20) {
                model.close(session)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(active ? Theme.tx : Theme.tx2)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(minWidth: 170, maxHeight: .infinity)
        .background(active ? Theme.bg : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 0.5) }
        .contentShape(.rect)
        .onTapGesture { model.activeSessionID = session.id }
    }
}

/// Сессия: хлебные крошки · терминал · статус-бар.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let group = session.host.group {
                    Text(group)
                    Text("›").accessibilityHidden(true)
                }
                Text(session.host.alias).fontWeight(.semibold).foregroundStyle(Theme.tx)
                Spacer()
                Button("Изменить хост") { model.editor = EditorRequest(original: session.host) }
                    .buttonStyle(.relaya(.ghost, height: 24))
                Button("SFTP") {}.buttonStyle(.relaya(.ghost, height: 24)).disabled(true).help("v0.2")
                Button("Туннели") {}.buttonStyle(.relaya(.ghost, height: 24)).disabled(true).help("v0.2")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.tx2)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 32)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 0.5) }

            TerminalView(host: session.host)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: Theme.termBg))

            HStack(spacing: 14) {
                Text(session.host.subtitle)
                if session.host.usesKey {
                    Text("ключ").foregroundStyle(Theme.grn)
                } else {
                    Text("пароль / ключ по умолчанию").foregroundStyle(Theme.org)
                }
                Spacer()
                Text("UTF-8")
                Text("xterm-256color")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.tx2)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Theme.bar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        }
    }
}

/// Терминал запускает системный `/usr/bin/ssh` — так ~/.ssh/config, ssh-agent, Keychain
/// и ProxyJump работают ровно как в Terminal.app.
struct TerminalView: NSViewRepresentable {
    let host: SSHHost

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont(name: "SF Mono", size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = Theme.termBg
        view.nativeForegroundColor = Theme.termTx
        view.caretColor = Theme.termTx
        view.startProcess(executable: "/usr/bin/ssh", args: [host.alias])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
