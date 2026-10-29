import SwiftUI
import SwiftTerm

struct SessionTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.sessions) { session in
                    let active = session.id == model.activeSessionID
                    HStack(spacing: 6) {
                        Text(session.host.alias).lineLimit(1)
                        Button {
                            model.close(session)
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(active ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                    .onTapGesture { model.activeSessionID = session.id }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

/// Терминал запускает системный `/usr/bin/ssh` — так ~/.ssh/config, ssh-agent, Keychain
/// и ProxyJump работают ровно как в Terminal.app.
struct TerminalSessionView: NSViewRepresentable {
    let session: Session

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.startProcess(executable: "/usr/bin/ssh", args: [session.host.alias])
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
