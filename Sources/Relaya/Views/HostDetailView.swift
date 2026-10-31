import SwiftUI
import RelayaCore

/// Карточка хоста без активной сессии (UI_SPEC 3.3).
struct HostDetailView: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(host.alias).font(.title2.bold())
                            ForEach(host.tags, id: \.self) { TagChip(tag: $0) }
                        }
                        Text(host.subtitle).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // «Подключить» — в тулбаре окна (⌘T), здесь не дублируем.
                    Button(L("Файлы")) { model.openFiles(host) }.buttonStyle(.relaya)
                    Button(L("Изменить")) { model.editor = EditorRequest(original: host) }.buttonStyle(.relaya)
                }
                LabeledContent {
                    if model.detectingOS.contains(host.alias) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(host.os == nil ? L("Определить") : L("Проверить снова")) {
                            Task { await model.detectOS(for: host.alias) }
                        }
                        .buttonStyle(.relaya(.normal, height: 24))
                    }
                } label: {
                    Label { Text(host.os?.title ?? L("ОС не определена")) } icon: { OSIcon(os: host.os, size: 18) }
                }
                if !host.usesKey {
                    LabeledContent(L("Ключ не указан — скорее всего, вход по паролю.")) {
                        Button(L("Настроить вход по ключу")) { model.keyWizard = KeyWizardRequest(host: host) }
                            .buttonStyle(.relaya(.primary, height: 24))
                    }
                }
            }

            panel { HostStatsPanel(host: host) }
            // Загрузка — здесь: у пустой панели (Docker ещё не опрошен) .task не срабатывает.
            if hasDocker { panel { DockerPanel(host: host) } }
            if host.tmux { panel { TmuxPanel(host: host) } }

            HostPanelView(host: host)

            Section(L("Порты")) {
                PortsPanel(host: host)
            }

            Section(L("Подключение")) {
                info(L("Адрес"), host.hostName ?? host.alias)
                info(L("Пользователь"), host.user ?? "—")
                info(L("Порт"), String(host.port ?? 22))
                info("ProxyJump", host.proxyJump ?? "—")
            }
            Section(L("Аутентификация")) {
                info(L("Ключ"), host.identityFile ?? L("по умолчанию / пароль"))
                info(L("Агент-форвардинг"), host.forwardAgent == true ? L("да") : L("нет"))
            }
            Section("ssh") {
                info(L("Команда"), "ssh \(host.alias)")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(ThemeStore.native ? .automatic : .hidden)
        .background(Theme.content)
        .task(id: host.alias) {
            await model.refreshDocker(host, interactive: false)
            await model.refreshPanel(host, interactive: false)
        }
    }

    /// Блок Docker — только если на хосте он есть (или есть что сказать: нет прав, ошибка).
    private var hasDocker: Bool {
        switch model.docker[host.alias] {
        case nil, .notInstalled?: false
        default: true
        }
    }

    /// Панели со своим заголовком — строкой формы без отступов и фона.
    private func panel<P: View>(@ViewBuilder _ content: () -> P) -> some View {
        Section {
            content()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(model.hosts.isEmpty ? L("Добавьте первый хост") : L("Выберите хост"), systemImage: "terminal")
        } description: {
            Text(L("Ваши ключи живут в ~/.ssh, а не у нас.\nХосты Relaya — это ваш ~/.ssh/config."))
        } actions: {
            Button(L("Добавить хост")) { model.add(nil) }.buttonStyle(.borderedProminent)
            Button(L("Перечитать ~/.ssh/config")) { model.reloadHosts() }
        }
    }
}
