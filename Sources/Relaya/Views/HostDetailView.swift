import SwiftUI
import RelayaCore

/// Карточка хоста без активной сессии (UI_SPEC 3.3).
struct HostDetailView: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    var body: some View {
        Form {
            Section {
                LabeledContent("Адрес", value: host.hostName ?? host.alias)
                LabeledContent("Пользователь", value: host.user ?? "—")
                LabeledContent("Порт", value: String(host.port ?? 22))
                if let jump = host.proxyJump { LabeledContent("ProxyJump", value: jump) }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.alias).font(.title2.bold())
                    Text(host.subtitle).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }

            Section("Аутентификация") {
                LabeledContent("Ключ", value: host.identityFile ?? "по умолчанию / пароль")
            }

            Section {
                Button("Подключить") { model.connect(host) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .formStyle(.grouped)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Выберите хост", systemImage: "terminal")
        } description: {
            Text(model.hosts.isEmpty
                 ? "Ваши хосты живут в ~/.ssh/config. Добавьте туда хост — Relaya подхватит его."
                 : "Ваши ключи живут в ~/.ssh, а не у нас.")
        } actions: {
            Button("Перечитать ~/.ssh/config") { model.reloadHosts() }
        }
    }
}
