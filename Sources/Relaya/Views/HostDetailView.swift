import SwiftUI
import RelayaCore

/// Карточка хоста без активной сессии (UI_SPEC 3.3).
struct HostDetailView: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(host.alias).font(.system(size: 22, weight: .bold))
                            ForEach(host.tags, id: \.self) { TagChip(tag: $0) }
                        }
                        Text(host.subtitle)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.tx2)
                    }
                    Spacer()
                    // «Подключить» — в тулбаре окна (⌘T), здесь не дублируем.
                    Button(L("Файлы")) { model.sftpHost = host }
                        .buttonStyle(.relaya)
                    Button(L("Изменить")) { model.editor = EditorRequest(original: host) }
                        .buttonStyle(.relaya)
                }

                if !host.usesKey {
                    HStack(spacing: 10) {
                        Text(L("Ключ не указан — скорее всего, вход по паролю."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L("Настроить вход по ключу")) { model.keyWizard = KeyWizardRequest(host: host) }
                            .buttonStyle(.relaya(.primary, height: 24))
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.accTint, in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
                }

                HStack(spacing: 10) {
                    OSIcon(os: host.os, size: 22)
                    Text(host.os?.title ?? L("ОС не определена"))
                        .foregroundStyle(host.os == nil ? Theme.tx2 : Theme.tx)
                    Spacer()
                    if model.detectingOS.contains(host.alias) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(host.os == nil ? L("Определить") : L("Проверить снова")) {
                            Task { await model.detectOS(for: host.alias) }
                        }
                        .buttonStyle(.relaya(.normal, height: 24))
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))

                InfoGroup(title: L("Подключение"), rows: [
                    (L("Адрес"), host.hostName ?? host.alias),
                    (L("Пользователь"), host.user ?? "—"),
                    (L("Порт"), String(host.port ?? 22)),
                    ("ProxyJump", host.proxyJump ?? "—"),
                ])
                InfoGroup(title: L("Аутентификация"), rows: [
                    (L("Ключ"), host.identityFile ?? L("по умолчанию / пароль")),
                    (L("Агент-форвардинг"), host.forwardAgent == true ? L("да") : L("нет")),
                ])
                InfoGroup(title: "ssh", rows: [(L("Команда"), "ssh \(host.alias)")])
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Theme.tx)
    }
}

private struct InfoGroup: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tx2)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack {
                        Text(row.0)
                        Spacer()
                        Text(row.1)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.tx2)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .overlay(alignment: .bottom) {
                        if i < rows.count - 1 { Divider().overlay(Theme.line2).padding(.leading, 12) }
                    }
                }
            }
            .background(Theme.bg2, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.tx2)
            Text(model.hosts.isEmpty ? L("Добавьте первый хост") : L("Выберите хост"))
                .font(.system(size: 17, weight: .bold))
            Text(L("Ваши ключи живут в ~/.ssh, а не у нас.\nХосты Relaya — это ваш ~/.ssh/config."))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.tx2)
            HStack(spacing: 8) {
                Button(L("Добавить хост")) { model.editor = EditorRequest(original: nil) }
                    .buttonStyle(.relayaPrimary)
                Button(L("Перечитать ~/.ssh/config")) { model.reloadHosts() }
                    .buttonStyle(.relaya)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
