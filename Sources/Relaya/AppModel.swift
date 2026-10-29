import AppKit
import Observation
import RelayaCore

/// Открытая вкладка с SSH-сессией.
struct Session: Identifiable, Hashable {
    let id = UUID()
    let host: SSHHost
    let controller: SessionController

    static func == (a: Session, b: Session) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Раздел в основной области окна.
enum Screen: Hashable {
    case hosts, keys, tunnels, snippets, desktops
}

/// Запуск мастера «Вход по ключу».
struct KeyWizardRequest: Identifiable {
    let id = UUID()
    let host: SSHHost
}

/// Открытие редактора хоста: `original == nil` — новый хост, `draft` — начальные значения полей.
struct EditorRequest: Identifiable {
    let id = UUID()
    let original: SSHHost?
    let draft: SSHHost

    init(original: SSHHost?, draft: SSHHost? = nil) {
        self.original = original
        self.draft = draft ?? original ?? SSHHost(alias: "")
    }
}

@MainActor
@Observable
final class AppModel {
    let store = SSHConfigStore()
    let keychain = KeychainStore()
    let settings = AppSettings()
    @ObservationIgnored lazy var tunnels = TunnelManager(askpassExecutable: askpassExecutable)

    var screen: Screen = .hosts
    var keyWizard: KeyWizardRequest?
    var sftpHost: SSHHost?
    var snippetPalette = false
    var desktops: [RemoteDesktop] = RemoteDesktopStore().load() {
        didSet { try? RemoteDesktopStore().save(desktops) }
    }
    var desktopStatus: [RemoteDesktop.ID: String] = [:]
    var snippets: [Snippet] = SnippetStore().load() {
        didSet { try? SnippetStore().save(snippets) }
    }
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingDone")

    var hosts: [SSHHost] = []
    var loadError: String?
    var searchText = ""
    /// Выбранные метки: показываются хосты, у которых есть все из них.
    var tagFilter: Set<String> = []

    var selectedHostID: SSHHost.ID?
    var sessions: [Session] = []
    var activeSessionID: Session.ID?

    var editor: EditorRequest?
    var pendingDelete: SSHHost?
    var alertMessage: String?
    /// Хост, для которого запрошено имя новой группы.
    var newGroupFor: SSHHost?
    /// Ждёт подтверждения: запретить вход по паролю на хосте.
    var pendingDisablePassword: SSHHost?

    /// Свёрнутые группы в sidebar — удобство одного пользователя, поэтому в UserDefaults, а не в конфиге.
    var collapsedGroups: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedGroups), forKey: "collapsedGroups") }
    }

    var selectedHost: SSHHost? { hosts.first { $0.id == selectedHostID } }
    var activeSession: Session? { sessions.first { $0.id == activeSessionID } }

    static let ungrouped = "Без группы"

    /// Все метки, в порядке частоты, без учёта регистра.
    var allTags: [String] {
        var counts: [String: (name: String, n: Int)] = [:]
        for tag in hosts.flatMap(\.tags) {
            counts[tag.lowercased(), default: (tag, 0)].n += 1
        }
        return counts.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }.map(\.name)
    }

    func toggleTagFilter(_ tag: String) {
        if tagFilter.contains(tag) { tagFilter.remove(tag) } else { tagFilter.insert(tag) }
    }

    var groups: [String] {
        Array(Set(hosts.compactMap(\.group).filter { !$0.isEmpty })).sorted()
    }

    /// Хосты без группы идут в «Без группы», остальные — по имени группы.
    var groupedHosts: [(name: String, hosts: [SSHHost])] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let wanted = Set(tagFilter.map { $0.lowercased() })
        let visible = hosts.filter { host in
            let tags = Set(host.tags.map { $0.lowercased() })
            guard wanted.isSubset(of: tags) else { return false }
            return query.isEmpty
                || host.alias.lowercased().contains(query)
                || host.subtitle.lowercased().contains(query)
                || tags.contains { $0.contains(query) }
        }
        return Dictionary(grouping: visible) { $0.group ?? "" }
            .sorted { lhs, rhs in
                if lhs.key.isEmpty != rhs.key.isEmpty { return rhs.key.isEmpty }
                return lhs.key < rhs.key
            }
            .map { (name: $0.key.isEmpty ? Self.ungrouped : $0.key, hosts: $0.value) }
    }

    func reloadHosts() {
        do {
            hosts = SSHConfigParser.parse(try store.loadDocument().text)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Хосты

    func save(_ host: SSHHost, originalAlias: String?) throws {
        var doc = try store.loadDocument()
        try doc.upsert(host, originalAlias: originalAlias)
        try store.save(doc)
        // Пароль привязан к адресу — при смене адреса/пользователя/порта переносим его.
        if let originalAlias, let old = hosts.first(where: { $0.alias == originalAlias }) {
            try? keychain.movePassword(from: old.keychainAccount, to: host.keychainAccount)
        }
        reloadHosts()
        selectedHostID = host.alias
    }

    /// Переносит хост в группу (`nil` — «Без группы»), меняя только комментарий `# relaya:` над блоком.
    func move(_ host: SSHHost, toGroup group: String?) {
        var updated = host
        let trimmed = group?.trimmingCharacters(in: .whitespaces)
        updated.group = trimmed?.isEmpty == false ? trimmed : nil
        guard updated.group != host.group else { return }
        do {
            try save(updated, originalAlias: host.alias)
            if let g = updated.group { collapsedGroups.remove(g) }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleCollapsed(_ group: String) {
        if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
    }

    func delete(_ host: SSHHost) {
        do {
            var doc = try store.loadDocument()
            try doc.remove(alias: host.alias)
            try store.save(doc)
            if selectedHostID == host.id { selectedHostID = nil }
            reloadHosts()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Сессии

    func connect(_ host: SSHHost) {
        screen = .hosts
        let controller = SessionController(host: host)
        controller.onOSGuessed = { [weak self] os in self?.setOS(os, for: host.alias, onlyIfUnknown: true) }
        let session = Session(host: host, controller: controller)
        if host.os == nil { Task { await detectOS(for: host.alias) } }
        sessions.append(session)
        activeSessionID = session.id
    }

    func close(_ session: Session) {
        guard let index = sessions.firstIndex(of: session) else { return }
        session.controller.terminate()
        sessions.remove(at: index)
        if activeSessionID == session.id {
            activeSessionID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        }
    }

    /// Открывает вкладку и выполняет команду, как только появится приглашение shell.
    /// Только по явному действию пользователя. Под root `sudo` убирается.
    func run(_ command: String, on host: SSHHost) {
        connect(host)
        let cmd = host.user == "root" ? command.replacingOccurrences(of: "sudo ", with: "") : command
        sessions.last?.controller.pendingCommand = cmd
    }

    /// Включает или отключает вход по паролю на сервере командой под его ОС.
    func setPasswordLogin(_ enabled: Bool, on host: SSHHost) {
        let host = current(host)
        run((host.os ?? .linux).passwordLoginCommand(enabled: enabled), on: host)
    }

    /// Открывает VNC в «Общем экране», RDP — в Windows App; при необходимости через SSH-туннель.
    func open(_ desktop: RemoteDesktop) async {
        desktopStatus[desktop.id] = nil
        var host = desktop.address
        var port = desktop.port
        let localPort = RemoteDesktop.freeLocalPort()
        if let tunnel = desktop.tunnel(localPort: localPort) {
            desktopStatus[desktop.id] = "Поднимаю SSH-туннель…"
            tunnels.start(tunnel, hosts: hosts)
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if case .failed(let m) = tunnels.status(of: tunnel) { desktopStatus[desktop.id] = "Туннель: \(m)"; return }
                if tunnels.status(of: tunnel) == .running { break }
            }
            host = "localhost"
            port = localPort
        }
        switch desktop.kind {
        case .vnc:
            guard let url = desktop.vncURL(host: host, port: port) else { return }
            NSWorkspace.shared.open(url)
            desktopStatus[desktop.id] = nil
        case .rdp:
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Relaya")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appending(path: "\(desktop.name.isEmpty ? "desktop" : desktop.name).rdp")
            do {
                try desktop.rdpFile(host: host, port: port).write(to: file, atomically: true, encoding: .utf8)
            } catch {
                desktopStatus[desktop.id] = error.localizedDescription
                return
            }
            if NSWorkspace.shared.urlForApplication(toOpen: file) == nil {
                desktopStatus[desktop.id] = "Нет приложения для RDP. Установите бесплатное Windows App от Microsoft из App Store."
                if let store = URL(string: "macappstore://apps.apple.com/app/id1295203466") { NSWorkspace.shared.open(store) }
                return
            }
            NSWorkspace.shared.open(file)
            desktopStatus[desktop.id] = nil
        }
    }

    func closeActiveSession() {
        if let activeSession { close(activeSession) }
    }

    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeSessionID = sessions[index].id
    }

    /// Актуальная версия хоста из config (во вкладке может лежать снимок на момент подключения).
    func current(_ host: SSHHost) -> SSHHost {
        hosts.first { $0.alias == host.alias } ?? host
    }

    var detectingOS: Set<String> = []

    /// Фоновая проверка ОС: отдельный неинтерактивный вход по ключу/агенту или паролю из Keychain.
    func detectOS(for alias: String) async {
        guard let host = hosts.first(where: { $0.alias == alias }), !detectingOS.contains(alias) else { return }
        detectingOS.insert(alias)
        defer { detectingOS.remove(alias) }
        let installer = KeyInstaller(askpassExecutable: askpassExecutable)
        let secret: KeyInstaller.SecretRef? = keychain.hasPassword(for: host.keychainAccount)
            ? .init(store: keychain, account: host.keychainAccount, kind: .password) : nil
        if let os = await installer.detectOS(alias: alias, password: secret) {
            setOS(os, for: alias, onlyIfUnknown: false)
        }
    }

    func setOS(_ os: ServerOS, for alias: String, onlyIfUnknown: Bool) {
        guard var host = hosts.first(where: { $0.alias == alias }), host.os != os else { return }
        if onlyIfUnknown, host.os != nil { return }
        host.os = os
        do {
            try save(host, originalAlias: alias)
        } catch {
            // Например, общий блок `Host a b` — ОС просто не запоминаем.
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        showOnboarding = false
    }

    /// Путь к самому Relaya — он же askpass-помощник для ssh.
    var askpassExecutable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    func isConnected(_ host: SSHHost) -> Bool {
        sessions.contains { $0.host.id == host.id }
    }
}
