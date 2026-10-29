import SwiftUI
import RelayaCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedHostID) {
            ForEach(model.groupedHosts, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.hosts) { host in
                        HostRow(host: host, connected: model.isConnected(host))
                            .tag(host.id)
                            .contextMenu {
                                Button("Подключить") { model.connect(host) }
                                Button("Копировать ssh-команду") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("ssh \(host.alias)", forType: .string)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.hosts.isEmpty {
                Text("Нет хостов в ~/.ssh/config")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HostRow: View {
    let host: SSHHost
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(host.alias)
                    if let env = host.environment {
                        Circle().fill(env.color).frame(width: 6, height: 6)
                    }
                }
                Text(host.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !host.usesKey {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Ключ не указан — возможно, вход по паролю")
            }
            Circle()
                .strokeBorder(connected ? Color.green : Color.secondary, lineWidth: 1)
                .background(Circle().fill(connected ? Color.green : .clear))
                .frame(width: 7, height: 7)
                .accessibilityLabel(connected ? "подключён" : "не подключён")
        }
    }
}

extension HostEnvironment {
    var color: Color {
        switch self {
        case .prod: .red
        case .staging: .orange
        case .dev: .green
        }
    }
}
