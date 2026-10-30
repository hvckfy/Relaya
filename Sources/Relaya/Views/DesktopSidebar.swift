import SwiftUI
import RelayaCore

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

/// Пустая область, когда выбран раздел удалённых столов, но не подключение.
struct DesktopsEmptyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(model.desktops.isEmpty ? L("Добавьте первое подключение") : L("Выберите подключение"),
                  systemImage: "display")
        } description: {
            Text(L("VNC и RDP открываются во вкладке Relaya. Пароль хранится в Keychain, можно подключаться через SSH-туннель."))
        } actions: {
            HStack {
                Button(L("Добавить VNC")) { model.add(.vnc) }
                Button(L("Добавить RDP")) { model.add(.rdp) }
            }
        }
    }
}
