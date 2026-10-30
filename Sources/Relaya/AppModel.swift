import AppKit
import Observation
import RelayaCore

/// Открытая вкладка: терминал, файлы (SFTP), VNC или RDP.
struct Session: Identifiable, Hashable {
    enum Kind {
        case terminal(SessionController)
        case files(SSHHost)
        case vnc(VNCSession)
        case rdp(RDPSession)
    }

    let id = UUID()
    let kind: Kind

    /// SSH-хост вкладки (для терминала и файлов).
    var host: SSHHost? {
        switch kind {
        case .terminal(let c): c.host
        case .files(let h): h
        case .vnc, .rdp: nil
        }
    }

    var controller: SessionController? {
        if case .terminal(let c) = kind { return c }
        return nil
    }

    var title: String {
        switch kind {
        case .terminal(let c): c.host.alias
        case .files(let h): h.alias
        case .vnc(let s): s.desktop.name.isEmpty ? s.desktop.address : s.desktop.name
        case .rdp(let s): s.desktop.name.isEmpty ? s.desktop.address : s.desktop.name
        }
    }

    var systemImage: String {
        switch kind {
        case .terminal: "terminal"
        case .files: "folder"
        case .vnc: "display"
        case .rdp: "pc"
        }
    }

    static func == (a: Session, b: Session) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Что показывает левое меню.
enum SidebarMode: String, CaseIterable, Identifiable {
    case ssh, sftp, vnc, rdp
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

/// Раздел в основной области окна.
enum Screen: Hashable {
    case hosts, keys, tunnels, snippets, desktops, agents
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
    /// Режим левого меню: SSH, SFTP, VNC или RDP.
    var sidebarMode: SidebarMode = SidebarMode(rawValue: UserDefaults.standard.string(forKey: "sidebarMode") ?? "") ?? .ssh {
        didSet { UserDefaults.standard.set(sidebarMode.rawValue, forKey: "sidebarMode") }
    }
    var selectedDesktopID: RemoteDesktop.ID?
    /// Редактор подключения VNC/RDP.
    var desktopEditor: RemoteDesktop?
    var sftpHost: SSHHost?
    var snippetPalette = false
    var desktops: [RemoteDesktop] = RemoteDesktopStore().load() {
        didSet { try? RemoteDesktopStore().save(desktops) }
    }
    var desktopStatus: [RemoteDesktop.ID: String] = [:]
    var snippets: [Snippet] = SnippetStore().load() {
        didSet { try? SnippetStore().save(snippets) }
    }
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingDone") && !RelayaPaths.isDemo

    var hosts: [SSHHost] = []
    var loadError: String?
    var searchText = ""
    /// Выбранные метки: показываются хосты, у которых есть все из них.
    var tagFilter: Set<String> = []

    var selectedHostID: SSHHost.ID?
    var sessions: [Session] = []
    /// Ввод из одного терминала рассылается во все остальные (кроме исключённых).
    var broadcastInput = false
    var broadcastExcluded: Set<Session.ID> = []
    /// Все терминалы одновременно, сеткой.
    var gridMode = false
    var terminalSessions: [Session] { sessions.filter { $0.controller != nil } }
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
    var selectedDesktop: RemoteDesktop? { desktops.first { $0.id == selectedDesktopID } }

    /// Рабочие столы для текущего режима меню (с учётом поиска).
    var visibleDesktops: [RemoteDesktop] {
        let kind: RemoteDesktop.Kind = sidebarMode == .rdp ? .rdp : .vnc
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return desktops.filter { d in
            d.kind == kind && (q.isEmpty || d.name.lowercased().contains(q) || d.summary.lowercased().contains(q))
        }
    }

    /// «Подключить» в тулбаре — по выбранному в текущем режиме.
    func connectSelection() {
        switch sidebarMode {
        case .ssh: if let h = selectedHost { connect(h) }
        case .sftp: if let h = selectedHost { openFiles(h) }
        case .vnc, .rdp: if let d = selectedDesktop { openDesktop(d) }
        }
    }

    var canConnectSelection: Bool {
        sidebarMode == .vnc || sidebarMode == .rdp ? selectedDesktop != nil : selectedHost != nil
    }

    /// «+» в тулбаре — новое подключение текущего типа.
    func addForCurrentMode() {
        switch sidebarMode {
        case .ssh, .sftp: editor = EditorRequest(original: nil)
        case .vnc: desktopEditor = RemoteDesktop(name: "", kind: .vnc, address: "")
        case .rdp: desktopEditor = RemoteDesktop(name: "", kind: .rdp, address: "")
        }
    }
    var activeSession: Session? { sessions.first { $0.id == activeSessionID } }

    static let ungrouped = L("Без группы")

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

    /// `tmuxSession` — подключиться к уже существующей сессии tmux (из списка в карточке хоста).
    func connect(_ host: SSHHost, tmuxSession: String? = nil) {
        screen = .hosts
        let useTmux = host.tmux && !RelayaPaths.isDemo
        let id = UUID()
        let name = tmuxSession ?? (useTmux ? Tmux.sessionName(alias: host.alias, id: id) : nil)
        let controller = SessionController(host: host, tmuxName: name, tmuxIdleMinutes: settings.tmuxIdleMinutes)
        if useTmux { Task { await cleanTmux(host) } }
        controller.onOSGuessed = { [weak self] os in self?.setOS(os, for: host.alias, onlyIfUnknown: true) }
        controller.onUserInput = { [weak self, weak controller] data in
            guard let self, let controller else { return }
            self.broadcast(data, from: controller)
        }
        let session = Session(kind: .terminal(controller))
        if host.os == nil, !RelayaPaths.isDemo { Task { await detectOS(for: host.alias) } }
        sessions.append(session)
        activeSessionID = session.id
    }

    func close(_ session: Session) {
        guard let index = sessions.firstIndex(of: session) else { return }
        switch session.kind {
        case .terminal(let c):
            c.terminate()
            // Вкладку закрыли сами — сессия tmux больше не нужна. Не вышло (нет доступа) — её уберёт таймер на сервере.
            if let name = c.tmuxName, !keepTmux.contains(name) {
                let host = c.host
                Task { _ = try? await exec(Tmux.killCommand([name]), on: host, interactive: false, reason: "") }
            }
            keepTmux.remove(c.tmuxName ?? "")
        case .vnc(let s): s.disconnect()
        case .rdp(let s): s.disconnect()
        case .files: break
        }
        sessions.remove(at: index)
        broadcastExcluded.remove(session.id)
        if terminalSessions.count < 2 {
            gridMode = false
            broadcastInput = false
        }
        if activeSessionID == session.id {
            activeSessionID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        }
    }

    /// Открывает вкладку и выполняет команду, как только появится приглашение shell.
    /// Только по явному действию пользователя. Под root `sudo` убирается.
    func run(_ command: String, on host: SSHHost) {
        connect(host)
        let cmd = host.user == "root" ? command.replacingOccurrences(of: "sudo ", with: "") : command
        sessions.last?.controller?.pendingCommand = cmd
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
            desktopStatus[desktop.id] = L("Поднимаю SSH-туннель…")
            tunnels.start(tunnel, hosts: hosts)
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if case .failed(let m) = tunnels.status(of: tunnel) { desktopStatus[desktop.id] = L("Туннель: %@", "\(m)"); return }
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
                desktopStatus[desktop.id] = L("Нет приложения для RDP. Установите бесплатное Windows App от Microsoft из App Store.")
                if let store = URL(string: "macappstore://apps.apple.com/app/id1295203466") { NSWorkspace.shared.open(store) }
                return
            }
            NSWorkspace.shared.open(file)
            desktopStatus[desktop.id] = nil
        }
    }

    /// Файлы хоста во вкладке (уже открытая вкладка того же хоста — активируется).
    func openFiles(_ host: SSHHost) {
        screen = .hosts
        if let existing = sessions.first(where: { if case .files(let h) = $0.kind { return h.alias == host.alias }; return false }) {
            activeSessionID = existing.id
            return
        }
        let session = Session(kind: .files(host))
        sessions.append(session)
        activeSessionID = session.id
    }

    /// VNC или RDP во вкладке окна.
    func openDesktop(_ desktop: RemoteDesktop) {
        screen = .hosts
        let session: Session
        switch desktop.kind {
        case .vnc:
            let s = VNCSession(desktop: desktop, model: self)
            session = Session(kind: .vnc(s))
            Task { await s.connect() }
        case .rdp:
            let s = RDPSession(desktop: desktop, model: self)
            session = Session(kind: .rdp(s))
            // Даём холсту разложиться: размер рабочего стола берётся из размера вкладки.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                await s.start()
            }
        }
        sessions.append(session)
        activeSessionID = session.id
    }

    func receivesBroadcast(_ session: Session) -> Bool {
        broadcastInput && session.controller != nil && !broadcastExcluded.contains(session.id)
    }

    /// Рассылка набранного пользователем во все другие терминалы, участвующие в рассылке.
    func broadcast(_ data: ArraySlice<UInt8>, from source: SessionController) {
        guard broadcastInput,
              let sourceSession = sessions.first(where: { $0.controller === source }),
              !broadcastExcluded.contains(sourceSession.id) else { return }
        for s in sessions where s.id != sourceSession.id && !broadcastExcluded.contains(s.id) {
            if let c = s.controller, !c.ended { c.terminal?.receiveBroadcast(data) }
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

    // MARK: - Команды на хосте

    /// Неинтерактивная команда на хосте: ключ/агент или пароль из Keychain (после Touch ID).
    /// `interactive` — вызвано пользователем: можно спросить Touch ID; иначе пароль берём, только если уже подтверждён.
    func exec(_ command: String, on host: SSHHost, interactive: Bool, reason: String,
              timeout: Duration = .seconds(20)) async throws -> ProcessResult {
        let ssh = await invocation(for: host, interactive: interactive, reason: reason)
        return try await ProcessRunner.run("/usr/bin/ssh", ssh.options + [ssh.alias, command],
                                           environment: ssh.environment, timeout: timeout)
    }

    /// Аргументы и окружение ssh для хоста — общие для exec и потоковых передач SFTP.
    func invocation(for host: SSHHost, interactive: Bool, reason: String) async -> SSHInvocation {
        let h = current(host)
        var args = ["-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10"]
        var env: [String: String] = [:]
        var usePassword = false
        if !h.usesKey, keychain.hasPassword(for: h.keychainAccount) {
            usePassword = SecretGate.shared.isUnlocked
            if !usePassword, interactive { usePassword = await SecretGate.shared.authorize(reason) }
        }
        if usePassword {
            env = KeyInstaller(askpassExecutable: askpassExecutable)
                .askpassEnvironment(.init(store: keychain, account: h.keychainAccount, kind: .password))
            args += KeyInstaller.passwordOnlyOptions
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        return SSHInvocation(alias: h.alias, options: args, environment: env)
    }

    // MARK: - tmux

    var tmux: [String: [TmuxSession]] = [:]
    var tmuxError: [String: String] = [:]
    /// Сессии, которые при закрытии вкладки остаются на сервере.
    @ObservationIgnored private var keepTmux: Set<String> = []

    private var openTmuxNames: Set<String> {
        Set(terminalSessions.compactMap { $0.controller?.tmuxName })
    }

    /// «Отсоединить и оставить на сервере»: срок — сутки без подключения, затем сервер её закроет.
    func detachKeeping(_ session: Session) async {
        guard let c = session.controller, let name = c.tmuxName else { return }
        do {
            let r = try await exec(Tmux.keepCommand(name: name), on: c.host, interactive: true,
                                   reason: L("Оставить сессию на %@", c.host.alias))
            guard r.succeeded else { alertMessage = r.message.isEmpty ? L("Команда не выполнена.") : r.message; return }
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        keepTmux.insert(name)
        close(session)
    }

    func refreshTmux(_ host: SSHHost, interactive: Bool) async {
        do {
            let r = try await exec(Tmux.listCommand, on: host, interactive: interactive,
                                   reason: L("Показать сессии tmux на %@", host.alias))
            guard r.succeeded else {
                tmuxError[host.alias] = L("Нет доступа к хосту без пароля.")
                return
            }
            tmux[host.alias] = Tmux.parse(r.stdout).filter { $0.name.hasPrefix(Tmux.hostPrefix(host.alias)) }
            tmuxError[host.alias] = nil
        } catch {
            tmuxError[host.alias] = error.localizedDescription
        }
    }

    /// Убрать брошенные и просроченные сессии хоста (подстраховка к таймеру на сервере).
    func cleanTmux(_ host: SSHHost) async {
        await refreshTmux(host, interactive: false)
        let stale = Tmux.stale(tmux[host.alias] ?? [], alias: host.alias, open: openTmuxNames,
                               ttlMinutes: settings.tmuxIdleMinutes)
        guard !stale.isEmpty else { return }
        _ = try? await exec(Tmux.killCommand(stale), on: host, interactive: false, reason: "")
        await refreshTmux(host, interactive: false)
    }

    func killTmux(_ names: [String], on host: SSHHost) async {
        // Открытые вкладки с этими сессиями закрываем без повторного kill.
        for s in terminalSessions where names.contains(s.controller?.tmuxName ?? "") { close(s) }
        do {
            _ = try await exec(Tmux.killCommand(names), on: host, interactive: true,
                               reason: L("Завершить сессии tmux на %@", host.alias))
        } catch {
            alertMessage = error.localizedDescription
        }
        await refreshTmux(host, interactive: false)
    }

    // MARK: - Docker

    var docker: [String: Docker.ListResult] = [:]
    var dockerLoading: Set<String> = []
    var dockerBusy: Set<String> = []

    func refreshDocker(_ host: SSHHost, interactive: Bool) async {
        guard !dockerLoading.contains(host.alias), !RelayaPaths.isDemo else { return }
        dockerLoading.insert(host.alias)
        defer { dockerLoading.remove(host.alias) }
        do {
            let r = try await exec(Docker.listCommand, on: host, interactive: interactive,
                                   reason: L("Показать контейнеры на %@", host.alias))
            // Без доступа (нужен пароль, а Touch ID не подтверждён) — тихо, блок просто не показываем.
            if !r.succeeded, r.stderr.contains("Permission denied") || r.status == 255 {
                if interactive { docker[host.alias] = .failed(L("Нет доступа к хосту без пароля.")) }
                return
            }
            docker[host.alias] = Docker.parse(stdout: r.stdout, stderr: r.stderr, status: r.status)
        } catch {
            docker[host.alias] = .failed(error.localizedDescription)
        }
    }

    /// start / stop / restart контейнера, затем обновить список.
    func dockerAction(_ action: String, _ container: DockerContainer, on host: SSHHost) async {
        dockerBusy.insert(container.id)
        defer { dockerBusy.remove(container.id) }
        do {
            let r = try await exec(Docker.actionCommand(action, container: container), on: host, interactive: true,
                                   reason: L("Управлять контейнерами на %@", host.alias), timeout: .seconds(60))
            if !r.succeeded { alertMessage = r.message.isEmpty ? L("Команда не выполнена.") : r.message }
        } catch {
            alertMessage = error.localizedDescription
        }
        await refreshDocker(host, interactive: false)
    }

    // MARK: - Состояние хоста

    var hostStats: [String: HostStats] = [:]
    var hostStatsError: [String: String] = [:]
    var hostStatsLoading: Set<String> = []

    /// Нагрузка/память/диск/аптайм одной командой по ssh. `interactive` — по кнопке: можно спросить Touch ID.
    func refreshStats(_ host: SSHHost, interactive: Bool) async {
        let h = current(host)
        guard !hostStatsLoading.contains(h.alias), !RelayaPaths.isDemo else { return }
        hostStatsLoading.insert(h.alias)
        defer { hostStatsLoading.remove(h.alias) }

        do {
            let r = try await exec(HostStats.probeCommand, on: h, interactive: interactive,
                                   reason: L("Показать состояние %@", h.alias))
            if let stats = HostStats.parse(r.stdout) {
                hostStats[h.alias] = stats
                hostStatsError[h.alias] = nil
            } else {
                hostStatsError[h.alias] = r.succeeded
                    ? L("Сервер не отдаёт данные (нужен Linux с /proc).")
                    : L("Нет доступа без пароля: настройте ключ или нажмите «Обновить», чтобы использовать пароль из Keychain.")
            }
        } catch {
            hostStatsError[h.alias] = error.localizedDescription
        }
    }

    /// Фоновая проверка ОС: отдельный неинтерактивный вход по ключу/агенту или паролю из Keychain.
    func detectOS(for alias: String) async {
        guard let host = hosts.first(where: { $0.alias == alias }), !detectingOS.contains(alias) else { return }
        detectingOS.insert(alias)
        defer { detectingOS.remove(alias) }
        let installer = KeyInstaller(askpassExecutable: askpassExecutable)
        // Фоновая проверка не вызывает Touch ID: пароль берём, только если доступ уже подтверждён.
        let secret: KeyInstaller.SecretRef? = keychain.hasPassword(for: host.keychainAccount) && SecretGate.shared.isUnlocked
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
        sessions.contains { $0.controller?.host.id == host.id }
    }
}
