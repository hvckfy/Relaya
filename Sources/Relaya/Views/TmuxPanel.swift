import SwiftUI
import RelayaCore

/// Сессии tmux, которые Relaya оставила на хосте: подключиться, завершить одну или все.
struct TmuxPanel: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    var body: some View {
        let list = model.tmux[host.alias] ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("tmux · \(list.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tx2)
                Spacer()
                if list.contains(where: { $0.attached == 0 }) {
                    Button(L("Завершить все")) {
                        Task { await model.killTmux(list.filter { $0.attached == 0 }.map(\.name), on: host) }
                    }
                    .buttonStyle(.relaya(.ghost, height: 20))
                }
                Button(L("Обновить")) { Task { await model.refreshTmux(host, interactive: true) } }
                    .buttonStyle(.relaya(.ghost, height: 20))
            }
            .padding(.leading, 4)
            VStack(spacing: 0) {
                if let e = model.tmuxError[host.alias] {
                    note(e)
                } else if list.isEmpty {
                    note(L("Сессий нет."))
                } else {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                        row(s)
                        if i < list.count - 1 { Divider().overlay(Theme.line2).padding(.leading, 12) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        }
        .task(id: host.alias) { await model.cleanTmux(host) }
    }

    private func row(_ s: TmuxSession) -> some View {
        HStack(spacing: 8) {
            Circle().fill(s.attached > 0 ? Theme.grn : Theme.tx2.opacity(0.4)).frame(width: 7, height: 7)
            Text(s.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
            if s.keep {
                Text(L("оставлена")).font(.system(size: 11)).foregroundStyle(Theme.org)
            }
            Spacer()
            Text(s.attached > 0 ? L("подключена")
                 : L("без подключения %@", (s.detachedAt ?? s.activity).formatted(.relative(presentation: .named))))
                .font(.system(size: 11.5)).foregroundStyle(Theme.tx2)
            Button(L("Подключиться")) { model.connect(host, tmuxSession: s.name) }
                .buttonStyle(.relaya(.ghost, height: 22))
                .disabled(s.attached > 0)
            Button(L("Завершить")) { Task { await model.killTmux([s.name], on: host) } }
                .buttonStyle(.relaya(.ghost, height: 22))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.tx2).padding(12)
    }
}
