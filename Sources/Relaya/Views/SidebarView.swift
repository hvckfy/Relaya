import SwiftUI
import RelayaCore

/// Sidebar (docs/design/Sidebar): группы хостов сверху, разделы Ключи/Туннели/Агенты снизу.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.groupedHosts, id: \.name) { group in
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text("\(group.hosts.count)")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tx2)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                        ForEach(group.hosts) { host in
                            HostRow(host: host,
                                    selected: model.selectedHostID == host.id,
                                    connected: model.isConnected(host))
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .overlay {
                if model.hosts.isEmpty {
                    VStack(spacing: 8) {
                        Text("Нет хостов").foregroundStyle(Theme.tx2)
                        Button("Добавить хост") { model.editor = EditorRequest(original: nil) }
                            .buttonStyle(.relaya(.normal, height: 24))
                    }
                }
            }

            Divider().overlay(Theme.line)
            VStack(spacing: 2) {
                NavRow(label: "Ключи", systemImage: "key")
                NavRow(label: "Туннели", systemImage: "arrow.left.arrow.right")
                NavRow(label: "Агенты (MCP)", systemImage: "sparkles")
            }
            .padding(8)
        }
        .background(Theme.side)
    }
}

struct HostRow: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    let selected: Bool
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tx2)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(host.alias).fontWeight(.medium)
                    if let env = host.environment {
                        Circle().fill(env.color).frame(width: 6, height: 6)
                            .accessibilityLabel(env.rawValue)
                    }
                }
                Text(host.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tx2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if !host.usesKey {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.org)
                    .help("Ключ не указан — вероятно, вход по паролю")
            }
            StatusDot(connected: connected)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(selected ? Theme.sel : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture(count: 2) { model.connect(host) }
        .onTapGesture { model.selectedHostID = host.id; model.activeSessionID = nil }
        .contextMenu {
            Button("Подключить") { model.connect(host) }
            Button("Изменить…") { model.editor = EditorRequest(original: host) }
            Button("Дублировать…") {
                var copy = host
                copy.alias += "-copy"
                model.editor = EditorRequest(original: nil, draft: copy)
            }
            Button("Копировать ssh-команду") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ssh \(host.alias)", forType: .string)
            }
            Divider()
            Button("Удалить…", role: .destructive) { model.pendingDelete = host }
        }
    }
}

private struct NavRow: View {
    let label: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(Theme.tx2)
            Text(label)
            Spacer()
            Text("скоро")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tx2)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx2)
        .padding(.horizontal, 8)
        .frame(height: 28)
    }
}
