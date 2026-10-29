import SwiftUI
import RelayaCore

/// Главное окно (docs/design/Main): sidebar · вкладки · хлебные крошки · терминал · статус-бар.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if !model.sessions.isEmpty {
                    SessionTabBar()
                }
                content
            }
            .background(Theme.bg)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                SearchField(text: $model.searchText)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.editor = EditorRequest(original: nil)
                } label: {
                    Label("Хост", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.relaya)
                .help("Новый хост (⇧⌘N)")

                Button {
                    if let host = model.selectedHost { model.connect(host) }
                } label: {
                    Label("Подключить", systemImage: "bolt.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.relayaPrimary)
                .disabled(model.selectedHost == nil)
                .help("Подключить (⌘T)")
            }
        }
        .toolbarBackground(Theme.bar, for: .windowToolbar)
        .sheet(item: $model.sftpHost) { host in
            SFTPView(host: host).environment(model)
        }
        .sheet(item: $model.keyWizard) { request in
            KeyWizardView(host: request.host, model: model)
                .environment(model)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.editor) { request in
            HostEditorView(original: request.original, draft: request.draft)
                .environment(model)
        }
        .confirmationDialog(
            "Удалить хост «\(model.pendingDelete?.alias ?? "")»?",
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            presenting: model.pendingDelete
        ) { host in
            Button("Удалить из ~/.ssh/config", role: .destructive) { model.delete(host) }
        } message: { _ in
            Text("Блок Host будет удалён из ~/.ssh/config. Копия прежнего файла сохранится в config.bak.")
        }
        .confirmationDialog(
            "Запретить вход по паролю на «\(model.pendingDisablePassword?.alias ?? "")»?",
            isPresented: Binding(get: { model.pendingDisablePassword != nil },
                                 set: { if !$0 { model.pendingDisablePassword = nil } }),
            presenting: model.pendingDisablePassword
        ) { host in
            Button("Запретить", role: .destructive) { model.setPasswordLogin(false, on: host) }
        } message: { host in
            Text(host.usesKey
                 ? "Откроется вкладка и выполнит команду на сервере. Входить можно будет только по ключу \(host.identityFile ?? "")."
                 : "У хоста не указан ключ! Если на сервере нет вашего ключа, вы потеряете доступ. Сначала настройте вход по ключу.")
        }
        .alert(
            "Новая группа",
            isPresented: Binding(get: { model.newGroupFor != nil }, set: { if !$0 { model.newGroupFor = nil } }),
            presenting: model.newGroupFor
        ) { host in
            NewGroupActions(host: host)
        } message: { host in
            Text("Хост «\(host.alias)» будет перенесён в неё.")
        }
        .alert(
            "Не получилось",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if model.screen == .keys {
            KeysView()
        } else if model.screen == .tunnels {
            TunnelsView()
        } else if let session = model.activeSession {
            SessionView(session: session)
                // id привязывает терминал к сессии — при переключении вкладок процесс не пересоздаётся.
                .id(session.id)
        } else if let host = model.selectedHost {
            HostDetailView(host: host)
        } else {
            EmptyStateView()
        }
    }
}

/// Поле имени и кнопки для алерта «Новая группа».
private struct NewGroupActions: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    @State private var name = ""

    var body: some View {
        TextField("Например: личные, работа", text: $name)
        Button("Создать") { model.move(host, toGroup: name) }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Отмена", role: .cancel) {}
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
            TextField("Хосты, действия, сниппеты…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.tx)
            Text("⌘K")
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
        }
        .foregroundStyle(Theme.tx2)
        .padding(.horizontal, 10)
        .frame(width: 380, height: 28)
        .background(Theme.sel, in: .capsule)
    }
}
