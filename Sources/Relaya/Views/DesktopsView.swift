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
                Text(L("Рабочие столы")).font(.system(size: 15, weight: .bold))
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
                    Text(L("Нет рабочих столов")).font(.system(size: 15, weight: .bold))
                    Text(L("VNC и RDP открываются прямо в окне Relaya.\nПароль хранится в Keychain, можно подключаться через SSH-туннель.\n«Общий экран» и Windows App — запасной вариант в меню «…»."))
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
        .background(Theme.content)
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
            Button(L("Подключить")) {
                // VNC и RDP — во встроенных окнах Relaya.
                openWindow(id: d.kind == .vnc ? "vnc" : "rdp", value: d.id)
            }
            .buttonStyle(.relayaPrimary)
            Menu {
                Button(d.kind == .vnc ? L("Открыть в «Общем экране» macOS") : L("Открыть в Windows App")) {
                    Task { await model.open(d) }
                }
                Button(L("Изменить…")) { editing = d }
                Divider()
                Button(L("Удалить"), role: .destructive) { model.desktops.removeAll { $0.id == d.id } }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(12)
        .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

struct DesktopEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var desktop: RemoteDesktop
    @State private var portText = ""
    @State private var useSSH = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("%@-подключение", "\(desktop.kind.title)")).font(.system(size: 17, weight: .bold))
            Form {
                Picker(L("Протокол"), selection: $desktop.kind) {
                    ForEach(RemoteDesktop.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: desktop.kind) { _, k in portText = String(k.defaultPort) }
                TextField(L("Название"), text: $desktop.name)
                TextField(L("Группа"), text: Binding(get: { desktop.group ?? "" },
                                                     set: { desktop.group = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                          prompt: Text(L("необязательно")))
                Toggle(L("Через SSH-туннель"), isOn: $useSSH)
                if useSSH {
                    Picker(L("SSH-хост"), selection: Binding(get: { desktop.viaSSHHost ?? "" }, set: { desktop.viaSSHHost = $0 })) {
                        ForEach(model.hosts) { Text($0.alias).tag($0.alias) }
                    }
                }
                TextField(useSSH ? L("Адрес с точки зрения сервера") : L("Адрес"), text: $desktop.address,
                          prompt: Text(useSSH ? "localhost" : "192.168.1.10"))
                TextField(L("Порт"), text: $portText)
                TextField(L("Пользователь"), text: $desktop.user, prompt: Text(L("необязательно")))
                if desktop.kind == .rdp {
                    Picker(L("Разрешение"), selection: Binding(
                        get: { desktop.rdpWidth.flatMap { w in desktop.rdpHeight.map { "\(w)x\($0)" } } ?? "fit" },
                        set: { v in
                            let parts = v.split(separator: "x").compactMap { Int($0) }
                            desktop.rdpWidth = parts.count == 2 ? parts[0] : nil
                            desktop.rdpHeight = parts.count == 2 ? parts[1] : nil
                        })) {
                        Text(L("По размеру окна (подстраивается на лету)")).tag("fit")
                        ForEach(RemoteDesktop.rdpResolutionPresets, id: \.0) { w, h in Text("\(w) × \(h)").tag("\(w)x\(h)") }
                        if let w = desktop.rdpWidth, let h = desktop.rdpHeight,
                           !RemoteDesktop.rdpResolutionPresets.contains(where: { $0 == (w, h) }) {
                            Text("\(w) × \(h)").tag("\(w)x\(h)")
                        }
                    }
                    HStack {
                        Text(L("Своё разрешение"))
                        Spacer()
                        TextField("1920", value: $desktop.rdpWidth, format: .number.grouping(.never))
                            .frame(width: 70).textFieldStyle(.roundedBorder)
                        Text("×")
                        TextField("1080", value: $desktop.rdpHeight, format: .number.grouping(.never))
                            .frame(width: 70).textFieldStyle(.roundedBorder)
                    }
                    Picker(L("Масштаб интерфейса"), selection: Binding(get: { desktop.rdpRetina ?? true }, set: { desktop.rdpRetina = $0 })) {
                        Text(L("Retina — крупный, как на Mac")).tag(true)
                        Text(L("100% — мельче, больше места")).tag(false)
                    }
                    Toggle(L("Во весь экран"), isOn: $desktop.fullScreen)
                        .help(L("Только для открытия во внешнем Windows App"))
                } else {
                    Picker(L("Масштаб"), selection: Binding(get: { desktop.scaleToFit ?? true }, set: { desktop.scaleToFit = $0 })) {
                        Text(L("По размеру окна")).tag(true)
                        Text(L("1:1, с прокруткой")).tag(false)
                    }
                }
            }
            .formStyle(.grouped)
            // В листе форма без своей подложки — иначе внутри один цвет, снаружи другой.
            .scrollContentBackground(.hidden)
            Text(L("Пароль Relaya спросит при первом подключении и, если разрешите, сохранит в Keychain."))
                .font(.system(size: 12)).foregroundStyle(Theme.tx2)
            if let e = result.validationError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button(L("Сохранить")) {
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
