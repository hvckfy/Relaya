import SwiftUI
import RelayaCore

/// Частые пробросы в один клик.
struct PortPreset: Identifiable {
    var id: String { name }
    let name: String
    let remotePort: Int
    let kind: Tunnel.Kind

    static let all: [PortPreset] = [
        PortPreset(name: "PostgreSQL", remotePort: 5432, kind: .local),
        PortPreset(name: "MySQL / MariaDB", remotePort: 3306, kind: .local),
        PortPreset(name: "Redis", remotePort: 6379, kind: .local),
        PortPreset(name: "MongoDB", remotePort: 27017, kind: .local),
        PortPreset(name: "HTTP :80", remotePort: 80, kind: .local),
        PortPreset(name: "HTTP :8080", remotePort: 8080, kind: .local),
        PortPreset(name: "Grafana :3000", remotePort: 3000, kind: .local),
        PortPreset(name: "Prometheus :9090", remotePort: 9090, kind: .local),
        PortPreset(name: "SOCKS", remotePort: 1080, kind: .dynamic),
    ]
}

/// Порты хоста: его туннели с переключателями и быстрый проброс.
/// Показывается в карточке хоста и во всплывающем окне «Порты» в сессии.
struct PortsPanel: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    @State private var editing: Tunnel?
    @State private var copied: Tunnel.ID?

    private var tunnels: [Tunnel] { model.tunnels.tunnels.filter { $0.hostAlias == host.alias } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tunnels.isEmpty {
                Text(L("Нет пробросов для этого хоста."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tx2)
            }
            ForEach(tunnels) { t in row(t) }
            HStack(spacing: 8) {
                Menu {
                    ForEach(PortPreset.all) { preset in
                        Button(preset.kind == .dynamic ? L("SOCKS-прокси") : preset.name) { forward(preset) }
                    }
                    Divider()
                    Button(L("Свой проброс…")) {
                        editing = Tunnel(name: "", hostAlias: host.alias, listenPort: 8080, targetHost: "localhost", targetPort: 80)
                    }
                } label: {
                    Label(L("Пробросить порт"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button(L("Все туннели")) { model.screen = .tunnels }
                    .buttonStyle(.relaya(.ghost, height: 22))
            }
        }
        .sheet(item: $editing) { t in TunnelEditor(tunnel: t).environment(model) }
    }

    private func row(_ t: Tunnel) -> some View {
        let status = model.tunnels.status(of: t)
        let running = status == .running || status == .starting
        return HStack(spacing: 8) {
            Circle().fill(color(status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name.isEmpty ? t.spec : t.name).font(.system(size: 12.5, weight: .medium))
                Text(t.summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tx2).lineLimit(1)
                if case .failed(let m) = status {
                    Text(m).font(.system(size: 11)).foregroundStyle(Theme.red).lineLimit(2)
                }
            }
            Spacer()
            if running, t.kind != .remote {
                Button(copied == t.id ? L("Скопировано") : "localhost:\(t.listenPort)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("localhost:\(t.listenPort)", forType: .string)
                    copied = t.id
                }
                .buttonStyle(.relaya(.ghost, height: 22))
                .help(L("Скопировать адрес"))
            }
            Toggle("", isOn: Binding(get: { running },
                                     set: { $0 ? model.tunnels.start(t, hosts: model.hosts) : model.tunnels.stop(t.id) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            Menu {
                Button(L("Изменить…")) { editing = t }
                Button(L("Удалить"), role: .destructive) { model.tunnels.delete(t.id) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func forward(_ preset: PortPreset) {
        let local = RemoteDesktop.preferredLocalPort(for: preset.remotePort)
        let tunnel = Tunnel(name: preset.kind == .dynamic ? L("SOCKS-прокси") : preset.name, hostAlias: host.alias,
                            kind: preset.kind, listenPort: local, targetHost: "localhost", targetPort: preset.remotePort)
        model.tunnels.upsert(tunnel)
        model.tunnels.start(tunnel, hosts: model.hosts)
    }

    private func color(_ s: TunnelManager.Status) -> Color {
        switch s {
        case .running: Theme.grn
        case .starting: Theme.org
        case .stopped: Theme.tx2.opacity(0.5)
        case .failed: Theme.red
        }
    }
}
