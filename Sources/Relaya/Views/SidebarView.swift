import SwiftUI
import RelayaCore

/// Элемент боковой панели.
enum SidebarItem: Hashable {
    case host(SSHHost.ID)
    case desktop(RemoteDesktop.ID)
    case tool(Screen)
}

/// Боковая панель в стиле source list macOS: секции «Хосты», «Удалённые столы», «Инструменты»,
/// внутри секций — сворачиваемые группы.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var selection: Binding<SidebarItem?> {
        Binding(get: {
            if model.screen != .hosts { return .tool(model.screen) }
            if let id = model.selectedHostID { return .host(id) }
            if let id = model.selectedDesktopID { return .desktop(id) }
            return nil
        }, set: { item in
            switch item {
            case .host(let id)?: model.select(host: id)
            case .desktop(let id)?: if let d = model.desktops.first(where: { $0.id == id }) { model.select(desktop: d) }
            case .tool(let screen)?: model.screen = screen
            case nil: break
            }
        })
    }

    var body: some View {
        List(selection: selection) {
            Section(isExpanded: model.isExpanded("section:hosts")) {
                ForEach(model.groupedHosts, id: \.name) { group in
                    DisclosureGroup(isExpanded: model.isExpanded(group.name)) {
                        ForEach(group.hosts) { host in
                            HostRow(host: host, connected: model.isConnected(host)).tag(SidebarItem.host(host.id))
                        }
                    } label: {
                        Label(group.name, systemImage: "folder").badge(group.hosts.count)
                    }
                }
                if model.hosts.isEmpty {
                    Button(L("Добавить хост")) { model.add(nil) }.buttonStyle(.link)
                }
            } header: {
                Text(L("Хосты"))
            }

            Section(isExpanded: model.isExpanded("section:desktops")) {
                ForEach(model.groupedDesktops, id: \.name) { group in
                    DisclosureGroup(isExpanded: model.isExpanded("desktop:" + group.name)) {
                        ForEach(group.desktops) { d in
                            DesktopRow(desktop: d).tag(SidebarItem.desktop(d.id))
                        }
                    } label: {
                        Label(group.name, systemImage: "folder").badge(group.desktops.count)
                    }
                }
                if model.desktops.isEmpty {
                    Menu(L("Добавить VNC или RDP")) {
                        Button("VNC") { model.add(.vnc) }
                        Button("RDP") { model.add(.rdp) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } header: {
                Text(L("Удалённые столы"))
            }

            Section(L("Инструменты")) {
                Label(L("Ключи"), systemImage: "key").tag(SidebarItem.tool(.keys))
                Label(L("Туннели"), systemImage: "arrow.left.arrow.right")
                    .badge(model.tunnels.activeCount)
                    .tag(SidebarItem.tool(.tunnels))
                Label(L("Сниппеты"), systemImage: "text.badge.plus")
                    .badge(model.snippets.count)
                    .tag(SidebarItem.tool(.snippets))
                Label(L("Агенты (MCP)"), systemImage: "sparkles").tag(SidebarItem.tool(.agents))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(ThemeStore.native ? .automatic : .hidden)
        .background(ThemeStore.native ? Color.clear : Theme.side)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if items.count == 1, let item = items.first { menu(for: item) }
        } primaryAction: { items in
            guard items.count == 1, let item = items.first else { return }
            switch item {
            case .host(let id): if let h = model.hosts.first(where: { $0.id == id }) { model.connect(h) }
            case .desktop(let id): if let d = model.desktops.first(where: { $0.id == id }) { model.openDesktop(d) }
            case .tool: break
            }
        }
        .overlay {
            if !model.searchText.isEmpty, model.groupedHosts.isEmpty, model.groupedDesktops.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }

    /// Короткое контекстное меню: частые действия. Остальное — в карточке и меню «Хост».
    @ViewBuilder private func menu(for item: SidebarItem) -> some View {
        switch item {
        case .host(let id):
            if let host = model.hosts.first(where: { $0.id == id }) { HostMenuItems(host: host) }
        case .desktop(let id):
            if let d = model.desktops.first(where: { $0.id == id }) {
                Button(L("Подключить")) { model.openDesktop(d) }
                Button(L("Открыть в отдельном окне")) { openWindow(id: d.kind == .vnc ? "vnc" : "rdp", value: d.id) }
                Divider()
                Button(L("Изменить…")) { model.desktopEditor = d }
                Button(L("Удалить…"), role: .destructive) {
                    model.desktops.removeAll { $0.id == d.id }
                    if model.selectedDesktopID == d.id { model.selectedDesktopID = nil }
                }
            }
        case .tool:
            EmptyView()
        }
    }
}

/// Действия над хостом: контекстное меню в боковой панели и меню «Хост» в строке меню.
struct HostMenuItems: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    var shortcuts = false

    var body: some View {
        Button(L("Подключить")) { model.connect(host) }
        Button(L("Открыть файлы (SFTP)")) { model.openFiles(host) }
            .keyboardShortcut(shortcuts ? KeyboardShortcut("o", modifiers: [.command, .shift]) : nil)
        Divider()
        Button(L("Изменить…")) { model.editor = EditorRequest(original: host) }
            .keyboardShortcut(shortcuts ? KeyboardShortcut("e") : nil)
        Button(L("Дублировать")) {
            var copy = host
            copy.alias += "-copy"
            model.editor = EditorRequest(original: nil, draft: copy)
        }
        .keyboardShortcut(shortcuts ? KeyboardShortcut("d") : nil)
        Menu(L("Переместить в группу")) {
            ForEach(model.groups.filter { $0 != host.group }, id: \.self) { g in
                Button(g) { model.move(host, toGroup: g) }
            }
            if host.group != nil {
                Button(AppModel.ungrouped) { model.move(host, toGroup: nil) }
            }
            Divider()
            Button(L("Новая группа…")) { model.newGroupFor = host }
        }
        Button(L("Копировать ssh-команду")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("ssh \(host.alias)", forType: .string)
        }
        if shortcuts {
            Divider()
            Button(L("Настроить вход по ключу…")) { model.keyWizard = KeyWizardRequest(host: host) }
            Button(L("Определить ОС")) { Task { await model.detectOS(for: host.alias) } }
            if host.os != .windows {
                Menu(L("Вход по паролю на сервере")) {
                    Button(L("Разрешить")) { model.setPasswordLogin(true, on: host) }
                    Button(L("Запретить…")) { model.pendingDisablePassword = host }
                }
            }
        }
        Divider()
        Button(L("Удалить…"), role: .destructive) { model.pendingDelete = host }
    }
}

struct HostRow: View {
    let host: SSHHost
    let connected: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(host.alias)
                    ForEach(host.tags.prefix(2), id: \.self) { tag in
                        Circle().fill(TagStyle.color(tag)).frame(width: 6, height: 6)
                            .help(tag)
                            .accessibilityLabel(L("метка %@", "\(tag)"))
                    }
                }
                Text(host.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            OSIcon(os: host.os, size: 16)
        }
        .badge(connected ? Text(Image(systemName: "circle.fill")).foregroundStyle(.green).font(.system(size: 7)) : nil)
        .help(host.usesKey ? host.subtitle : L("Ключ не указан — вероятно, вход по паролю"))
    }
}

struct DesktopRow: View {
    @Environment(AppModel.self) private var model
    let desktop: RemoteDesktop

    var body: some View {
        let open = model.sessions.contains { s in
            switch s.kind {
            case .vnc(let v): v.desktop.id == desktop.id
            case .rdp(let r): r.desktop.id == desktop.id
            default: false
            }
        }
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(desktop.displayName)
                Text(desktop.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: desktop.kind == .vnc ? "display" : "pc")
        }
        .badge(Text(open ? "● " + desktop.kind.title : desktop.kind.title))
    }
}

