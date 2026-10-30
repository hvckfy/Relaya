import SwiftUI
import RelayaCore

/// Экран «Рабочие столы» (UI_SPEC 3.11): VNC и RDP, в т.ч. через SSH-туннель.
struct DesktopsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RemoteDesktop?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Рабочие столы").font(.system(size: 15, weight: .bold))
                Spacer()
                Button("VNC…") { editing = RemoteDesktop(name: "", kind: .vnc, address: "") }.buttonStyle(.relaya)
                Button("RDP…") { editing = RemoteDesktop(name: "", kind: .rdp, address: "") }.buttonStyle(.relayaPrimary)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }

            if model.desktops.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "display.2").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.tx2)
                    Text("Нет рабочих столов").font(.system(size: 15, weight: .bold))
                    Text("VNC и RDP открываются прямо в окне Relaya.\nПароль хранится в Keychain, можно подключаться через SSH-туннель.\n«Общий экран» и Windows App — запасной вариант в меню «…».")
                        .multilineTextAlignment(.center).foregroundStyle(Theme.tx2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.desktops) { d in row(d) }
                    }
                    .padding(16)
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .background(Theme.bg)
        .sheet(item: $editing) { d in DesktopEditor(desktop: d).environment(model) }
    }

    private func row(_ d: RemoteDesktop) -> some View {
        HStack(spacing: 12) {
            Image(systemName: d.kind == .vnc ? "display" : "pc")
                .font(.system(size: 18)).foregroundStyle(Theme.acc).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.name.isEmpty ? d.address : d.name).fontWeight(.semibold)
                    Text(d.kind.title).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).frame(height: 18).background(Theme.sel, in: .capsule)
                }
                Text(d.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
                if let status = model.desktopStatus[d.id] {
                    Text(status).font(.system(size: 12)).foregroundStyle(Theme.org).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Подключить") {
                // VNC и RDP — во встроенных окнах Relaya.
                openWindow(id: d.kind == .vnc ? "vnc" : "rdp", value: d.id)
            }
            .buttonStyle(.relayaPrimary)
            Menu {
                Button(d.kind == .vnc ? "Открыть в «Общем экране» macOS" : "Открыть в Windows App") {
                    Task { await model.open(d) }
                }
                Button("Изменить…") { editing = d }
                Divider()
                Button("Удалить", role: .destructive) { model.desktops.removeAll { $0.id == d.id } }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(12)
        .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

private struct DesktopEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var desktop: RemoteDesktop
    @State private var portText = ""
    @State private var useSSH = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(desktop.kind.title)-подключение").font(.system(size: 17, weight: .bold))
            Form {
                Picker("Протокол", selection: $desktop.kind) {
                    ForEach(RemoteDesktop.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: desktop.kind) { _, k in portText = String(k.defaultPort) }
                TextField("Название", text: $desktop.name)
                Toggle("Через SSH-туннель", isOn: $useSSH)
                if useSSH {
                    Picker("SSH-хост", selection: Binding(get: { desktop.viaSSHHost ?? "" }, set: { desktop.viaSSHHost = $0 })) {
                        ForEach(model.hosts) { Text($0.alias).tag($0.alias) }
                    }
                }
                TextField(useSSH ? "Адрес с точки зрения сервера" : "Адрес", text: $desktop.address,
                          prompt: Text(useSSH ? "localhost" : "192.168.1.10"))
                TextField("Порт", text: $portText)
                TextField("Пользователь", text: $desktop.user, prompt: Text("необязательно"))
                if desktop.kind == .rdp {
                    Toggle("Во весь экран", isOn: $desktop.fullScreen)
                } else {
                    Picker("Масштаб", selection: Binding(get: { desktop.scaleToFit ?? true }, set: { desktop.scaleToFit = $0 })) {
                        Text("По размеру окна").tag(true)
                        Text("1:1, с прокруткой").tag(false)
                    }
                }
            }
            .formStyle(.grouped)
            Text("Пароль Relaya спросит при первом подключении и, если разрешите, сохранит в Keychain.")
                .font(.system(size: 12)).foregroundStyle(Theme.tx2)
            if let e = result.validationError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    let d = result
                    if let i = model.desktops.firstIndex(where: { $0.id == d.id }) { model.desktops[i] = d } else { model.desktops.append(d) }
                    dismiss()
                }
                .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                .disabled(result.validationError != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(Theme.bg)
        .onAppear {
            portText = String(desktop.port)
            useSSH = desktop.viaSSHHost != nil
            if useSSH, desktop.viaSSHHost?.isEmpty != false { desktop.viaSSHHost = model.hosts.first?.alias }
        }
        .onChange(of: useSSH) { _, on in
            desktop.viaSSHHost = on ? (desktop.viaSSHHost ?? model.hosts.first?.alias) : nil
            if on, desktop.address.isEmpty { desktop.address = "localhost" }
        }
    }

    private var result: RemoteDesktop {
        var d = desktop
        d.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        d.address = d.address.trimmingCharacters(in: .whitespaces)
        if d.viaSSHHost?.isEmpty == true { d.viaSSHHost = nil }
        return d
    }
}
