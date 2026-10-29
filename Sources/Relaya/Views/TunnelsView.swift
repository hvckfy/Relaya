import SwiftUI
import RelayaCore

/// Экран «Туннели» (UI_SPEC 3.9): пробросы портов и их состояние.
struct TunnelsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Tunnel?

    private var manager: TunnelManager { model.tunnels }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Туннели").font(.system(size: 15, weight: .bold))
                Text("\(manager.tunnels.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
                Spacer()
                Button("Новый туннель…") {
                    editing = Tunnel(name: "", hostAlias: model.selectedHost?.alias ?? model.hosts.first?.alias ?? "",
                                     listenPort: 8080, targetHost: "localhost", targetPort: 80)
                }
                .buttonStyle(.relayaPrimary)
                .disabled(model.hosts.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }

            if manager.tunnels.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.tx2)
                    Text("Нет туннелей").font(.system(size: 15, weight: .bold))
                    Text("Например, база данных с сервера на localhost:15432\nили SOCKS-прокси через ваш VPS.")
                        .multilineTextAlignment(.center).foregroundStyle(Theme.tx2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.tunnels) { t in
                            TunnelRow(tunnel: t, editing: $editing)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .background(Theme.bg)
        .sheet(item: $editing) { t in
            TunnelEditor(tunnel: t).environment(model)
        }
    }
}

private struct TunnelRow: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel
    @Binding var editing: Tunnel?

    var body: some View {
        let status = model.tunnels.status(of: tunnel)
        HStack(spacing: 12) {
            Circle().fill(color(status)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tunnel.name.isEmpty ? tunnel.spec : tunnel.name).fontWeight(.semibold)
                    Text(tunnel.kind.flag).font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Theme.sel, in: .capsule)
                    if tunnel.autoStart {
                        Text("автозапуск").font(.system(size: 11)).foregroundStyle(Theme.tx2)
                    }
                }
                Text(tunnel.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
                if case .failed(let message) = status {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer()
            switch status {
            case .running, .starting:
                Button("Остановить") { model.tunnels.stop(tunnel.id) }.buttonStyle(.relaya)
            case .stopped, .failed:
                Button("Запустить") { model.tunnels.start(tunnel, hosts: model.hosts) }.buttonStyle(.relayaPrimary)
            }
            Menu {
                Button("Изменить…") { editing = tunnel }
                if tunnel.kind == .local {
                    Button("Открыть http://localhost:\(tunnel.listenPort)") {
                        if let url = URL(string: "http://localhost:\(tunnel.listenPort)") { NSWorkspace.shared.open(url) }
                    }
                }
                Button("Копировать ssh-команду") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("ssh -N \(tunnel.kind.flag) \(tunnel.spec) \(tunnel.hostAlias)", forType: .string)
                }
                Divider()
                Button("Удалить", role: .destructive) { model.tunnels.delete(tunnel.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(12)
        .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
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

private struct TunnelEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var tunnel: Tunnel
    @State private var listen = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.tunnels.tunnels.contains { $0.id == tunnel.id } ? "Изменить туннель" : "Новый туннель")
                .font(.system(size: 17, weight: .bold))
            Form {
                TextField("Название", text: $tunnel.name, prompt: Text("например, Postgres prod"))
                Picker("Хост", selection: $tunnel.hostAlias) {
                    ForEach(model.hosts) { Text("\($0.alias) — \($0.subtitle)").tag($0.alias) }
                }
                Picker("Тип", selection: $tunnel.kind) {
                    ForEach(Tunnel.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(tunnel.kind == .remote ? "Порт на сервере" : "Локальный порт", text: $listen)
                if tunnel.kind != .dynamic {
                    TextField(tunnel.kind == .remote ? "Адрес на этом Mac" : "Адрес (с точки зрения сервера)",
                              text: $tunnel.targetHost)
                    TextField("Порт назначения", text: $target)
                }
                Toggle("Запускать вместе с Relaya", isOn: $tunnel.autoStart)
                Text(preview.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
            }
            .formStyle(.grouped)
            if let e = preview.validationError {
                Text(e).font(.system(size: 12)).foregroundStyle(Theme.red)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    model.tunnels.upsert(preview)
                    dismiss()
                }
                .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                .disabled(preview.validationError != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.bg)
        .onAppear {
            listen = String(tunnel.listenPort)
            target = tunnel.targetPort == 0 ? "" : String(tunnel.targetPort)
        }
    }

    private var preview: Tunnel {
        var t = tunnel
        t.listenPort = Int(listen.trimmingCharacters(in: .whitespaces)) ?? 0
        t.targetPort = Int(target.trimmingCharacters(in: .whitespaces)) ?? 0
        t.targetHost = t.targetHost.trimmingCharacters(in: .whitespaces)
        return t
    }
}
