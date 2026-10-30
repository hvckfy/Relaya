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
            // Рабочая область — на всё окно, иначе у пустых экранов фон виден только под карточкой.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { WorkspaceBackground() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.allTags.isEmpty {
                    Menu {
                        ForEach(model.allTags, id: \.self) { tag in
                            Toggle(tag, isOn: Binding(get: { model.tagFilter.contains(tag) },
                                                      set: { _ in model.toggleTagFilter(tag) }))
                        }
                        if !model.tagFilter.isEmpty {
                            Divider()
                            Button(L("Сбросить фильтр меток")) { model.tagFilter = [] }
                        }
                    } label: {
                        Label(L("Метки"), systemImage: model.tagFilter.isEmpty
                              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help(L("Фильтр по меткам"))
                }
                Menu {
                    Button(L("Хост SSH…")) { model.add(nil) }
                    Button(L("Подключение VNC…")) { model.add(.vnc) }
                    Button(L("Подключение RDP…")) { model.add(.rdp) }
                } label: {
                    Label(L("Добавить"), systemImage: "plus")
                }
                .help(L("Новый хост (⇧⌘N)"))

                Button {
                    model.connectSelection()
                } label: {
                    Label(L("Подключить"), systemImage: "bolt.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.relayaPrimary)
                .disabled(!model.canConnectSelection)
                .help(L("Подключить (⌘T)"))
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: L("Хосты и подключения"))
        // Без своей заливки тулбара: сайдбар идёт на всю высоту окна (как в Finder),
        // а над рабочей областью виден её фон.
        .sheet(item: $model.desktopEditor) { d in
            DesktopEditor(desktop: d).environment(model)
        }
        .sheet(isPresented: $model.snippetPalette) {
            SnippetPalette().environment(model)
        }
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
            L("Удалить хост «%@»?", "\(model.pendingDelete?.alias ?? "")"),
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            presenting: model.pendingDelete
        ) { host in
            Button(L("Удалить из ~/.ssh/config"), role: .destructive) { model.delete(host) }
        } message: { _ in
            Text(L("Блок Host будет удалён из ~/.ssh/config. Копия прежнего файла сохранится в config.bak."))
        }
        .confirmationDialog(
            L("Запретить вход по паролю на «%@»?", "\(model.pendingDisablePassword?.alias ?? "")"),
            isPresented: Binding(get: { model.pendingDisablePassword != nil },
                                 set: { if !$0 { model.pendingDisablePassword = nil } }),
            presenting: model.pendingDisablePassword
        ) { host in
            Button(L("Запретить"), role: .destructive) { model.setPasswordLogin(false, on: host) }
        } message: { host in
            Text(host.usesKey
                 ? L("Откроется вкладка и выполнит команду на сервере. Входить можно будет только по ключу %@.", "\(host.identityFile ?? "")")
                 : L("У хоста не указан ключ! Если на сервере нет вашего ключа, вы потеряете доступ. Сначала настройте вход по ключу."))
        }
        .alert(
            L("Новая группа"),
            isPresented: Binding(get: { model.newGroupFor != nil }, set: { if !$0 { model.newGroupFor = nil } }),
            presenting: model.newGroupFor
        ) { host in
            NewGroupActions(host: host)
        } message: { host in
            Text(L("Хост «%@» будет перенесён в неё.", "\(host.alias)"))
        }
        .alert(
            L("Не получилось"),
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
        } else if model.screen == .snippets {
            SnippetsView()
        } else if model.screen == .desktops {
            DesktopsView()
        } else if model.screen == .agents {
            AgentsView()
        } else if model.gridMode, model.tileableSessions.count >= 2 {
            SessionGrid()
        } else if let session = model.activeSession {
            // id привязывает содержимое к вкладке — при переключении процессы не пересоздаются.
            Group {
                switch session.kind {
                case .terminal(let c): SessionView(session: session, controller: c).modifier(DockTarget())
                case .files(let h): SFTPView(host: h, embedded: true).modifier(DockTarget())
                case .vnc(let s): VNCContent(session: s).background(Color.black)
                case .rdp(let s): RDPContent(session: s).background(Color.black)
                }
            }
            .id(session.id)
        } else if model.sidebarMode == .vnc || model.sidebarMode == .rdp {
            if let desktop = model.selectedDesktop {
                DesktopDetailView(desktop: desktop)
            } else {
                DesktopsEmptyView()
            }
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
        TextField(L("Например: личные, работа"), text: $name)
        Button(L("Создать")) { model.move(host, toGroup: name) }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        Button(L("Отмена"), role: .cancel) {}
    }
}

/// Перетаскивание вкладки на открытый терминал: он и перетащенная вкладка становятся плитками.
private struct DockTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var hint: CGRect?

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            content
                .overlay(alignment: .topLeading) { DockHint(rect: hint) }
                .onDrop(of: [.plainText], delegate: TileDropDelegate(
                    model: model,
                    frames: { model.activeSessionID.map { [$0: bounds.insetBy(dx: 28, dy: 28)] } ?? [:] },
                    bounds: bounds, hint: $hint))
        }
    }
}

/// Фон рабочей области: цвет темы и, если выбрана, одна картинка на всё окно —
/// плитки, терминалы и разделы поверх неё полупрозрачные.
private struct WorkspaceBackground: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            Theme.bg
            if let image = settings.backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            }
        }
        .ignoresSafeArea()
    }
}
