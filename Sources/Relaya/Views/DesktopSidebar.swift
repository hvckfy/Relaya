import SwiftUI
import RelayaCore

/// Список VNC/RDP-подключений в левом меню (режимы VNC и RDP).
struct DesktopList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.visibleDesktops) { d in row(d) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .overlay {
            if model.visibleDesktops.isEmpty {
                VStack(spacing: 8) {
                    Text(model.searchText.isEmpty ? L("Нет подключений") : L("Ничего не найдено")).foregroundStyle(Theme.tx2)
                    if model.searchText.isEmpty {
                        Button(L("Добавить")) { model.addForCurrentMode() }
                            .buttonStyle(.relaya(.normal, height: 24))
                    }
                }
            }
        }
    }

    private func row(_ d: RemoteDesktop) -> some View {
        let selected = model.selectedDesktopID == d.id
        let open = model.sessions.contains { s in
            switch s.kind {
            case .vnc(let v): v.desktop.id == d.id
            case .rdp(let r): r.desktop.id == d.id
            default: false
            }
        }
        return HStack(spacing: 8) {
            Image(systemName: d.kind == .vnc ? "display" : "pc")
                .font(.system(size: 13))
                .foregroundStyle(Theme.acc)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name.isEmpty ? d.address : d.name).fontWeight(.medium)
                Text(d.summary).font(.system(size: 11)).foregroundStyle(Theme.tx2).lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusDot(connected: open)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(selected ? Theme.sel : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { model.selectedDesktopID = d.id; model.activeSessionID = nil; model.screen = .hosts }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openDesktop(d) })
        .contextMenu {
            Button(L("Подключить")) { model.openDesktop(d) }
            Button(L("Открыть в отдельном окне")) { openWindow(id: d.kind == .vnc ? "vnc" : "rdp", value: d.id) }
            Button(d.kind == .vnc ? L("Открыть в «Общем экране» macOS") : L("Открыть в Windows App")) {
                Task { await model.open(d) }
            }
            Divider()
            Button(L("Изменить…")) { model.desktopEditor = d }
            Button(L("Удалить"), role: .destructive) {
                model.desktops.removeAll { $0.id == d.id }
                if model.selectedDesktopID == d.id { model.selectedDesktopID = nil }
            }
        }
    }
}

/// Карточка VNC/RDP-подключения.
struct DesktopDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let desktop: RemoteDesktop

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: desktop.kind == .vnc ? "display" : "pc").foregroundStyle(Theme.acc)
                            Text(desktop.name.isEmpty ? desktop.address : desktop.name).font(.system(size: 22, weight: .bold))
                            Text(desktop.kind.title).font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8).frame(height: 20).background(Theme.sel, in: .capsule)
                        }
                        Text(desktop.summary).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.tx2)
                    }
                    Spacer()
                    Button(L("Изменить")) { model.desktopEditor = desktop }.buttonStyle(.relaya)
                }

                VStack(spacing: 0) {
                    row(L("Адрес"), desktop.address)
                    row(L("Порт"), String(desktop.port))
                    row(L("Пользователь"), desktop.user.isEmpty ? "—" : desktop.user)
                    row(L("Через SSH-туннель"), desktop.viaSSHHost ?? "—")
                    if desktop.kind == .vnc {
                        row(L("Масштаб"), desktop.scaleToFit == false ? L("1:1, с прокруткой") : L("По размеру окна"), last: true)
                    } else {
                        row(L("Во весь экран"), desktop.fullScreen ? L("да") : L("нет"), last: true)
                    }
                }
                .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))

                HStack(spacing: 8) {
                    Button(L("Открыть в отдельном окне")) { openWindow(id: desktop.kind == .vnc ? "vnc" : "rdp", value: desktop.id) }
                        .buttonStyle(.relaya)
                    Button(desktop.kind == .vnc ? L("Открыть в «Общем экране» macOS") : L("Открыть в Windows App")) {
                        Task { await model.open(desktop) }
                    }
                    .buttonStyle(.relaya(.ghost))
                }
                if let status = model.desktopStatus[desktop.id] {
                    Text(status).font(.system(size: 12)).foregroundStyle(Theme.org)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
    }

    private func row(_ label: String, _ value: String, last: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.tx2).textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            if !last { Divider().overlay(Theme.line2).padding(.leading, 12) }
        }
    }
}

/// Пустая область в режимах VNC/RDP, когда ничего не выбрано.
struct DesktopsEmptyView: View {
    @Environment(AppModel.self) private var model
    let kind: RemoteDesktop.Kind

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: kind == .vnc ? "display" : "pc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.tx2)
            Text(model.visibleDesktops.isEmpty ? L("Добавьте первое подключение") : L("Выберите подключение"))
                .font(.system(size: 17, weight: .bold))
            Text(kind == .vnc
                 ? L("VNC открывается во вкладке Relaya. Пароль хранится в Keychain, можно подключаться через SSH-туннель.")
                 : L("RDP открывается во вкладке Relaya: вход с NLA, пароль в Keychain, можно через SSH-туннель."))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.tx2)
                .frame(maxWidth: 420)
            Button(kind == .vnc ? L("Добавить VNC") : L("Добавить RDP")) { model.addForCurrentMode() }
                .buttonStyle(.relayaPrimary)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
