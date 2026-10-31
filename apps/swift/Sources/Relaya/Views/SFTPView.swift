import SwiftUI
import RelayaCore

/// Файлы на сервере по SFTP (UI_SPEC 3.8): навигация, скачивание, загрузка (в т.ч. из Finder).
struct SFTPView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: SSHHost
    /// Во вкладке окна, а не в отдельном листе: без кнопки «Готово» и фиксированного размера.
    var embedded = false

    @State private var path = ""
    @State private var pathField = ""
    @State private var files: [RemoteFile] = []
    @State private var selection = Set<RemoteFile.ID>()
    @State private var loading = false
    @State private var busy: String?
    @State private var error: String?
    @State private var newFolder = false
    @State private var newFolderName = ""
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @State private var queue = TransferQueue()
    @State private var edits: [RemoteEditSession] = []
    @State private var renaming: RemoteFile?
    @State private var renameText = ""

    private var client: SFTPClient {
        let usePassword = !host.usesKey && model.keychain.hasPassword(for: host.keychainAccount)
        return SFTPClient(alias: host.alias,
                          password: usePassword ? .init(store: model.keychain, account: host.keychainAccount, kind: .password, alias: host.alias) : nil,
                          askpassExecutable: model.askpassExecutable)
    }

    private var selectedFiles: [RemoteFile] { files.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Table(files, selection: $selection) {
                TableColumn(L("Имя")) { f in
                    Label {
                        Text(f.name)
                    } icon: {
                        Image(systemName: f.isDirectory ? "folder.fill" : f.isLink ? "arrow.up.right.square" : "doc")
                            .foregroundStyle(f.isDirectory ? Theme.acc : Theme.tx2)
                    }
                }
                TableColumn(L("Размер")) { f in
                    Text(f.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                        .foregroundStyle(Theme.tx2)
                }
                .width(90)
                TableColumn(L("Изменён")) { f in Text(f.modified).foregroundStyle(Theme.tx2) }.width(110)
                TableColumn(L("Права")) { f in
                    Text(f.permissions).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tx2)
                }
                .width(100)
            }
            .scrollContentBackground(embedded && ThemeStore.sessionOpacity < 1 ? .hidden : .automatic)
            .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
                if ids.count == 1, let f = files.first(where: { ids.contains($0.id) }), !f.isDirectory {
                    Button(L("Открыть в редакторе")) { edit(f) }
                }
                if ids.count == 1, let f = files.first(where: { ids.contains($0.id) }) {
                    Button(L("Переименовать…")) { renameText = f.name; renaming = f }
                }
                if !ids.isEmpty {
                    Button(L("Скачать…")) { download() }
                    Button(L("Удалить…"), role: .destructive) { confirmDelete = true }
                }
            } primaryAction: { ids in
                if ids.count == 1, let f = files.first(where: { ids.contains($0.id) }) {
                    if f.isDirectory || f.isLink { open(SFTPClient.join(path, f.name)) } else { edit(f) }
                }
            }
            .overlay {
                if loading { ProgressView() }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.acc, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .padding(8)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                upload(urls: urls.filter(\.isFileURL))
                return true
            } isTargeted: { dropTargeted = $0 }
            if !queue.items.isEmpty { TransferList(queue: queue) }
            statusBar
        }
        .background { shortcuts }
        .frame(width: embedded ? nil : 860, height: embedded ? nil : 560)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(embedded ? Theme.session : Theme.bg)
        .task { await start() }
        .onDisappear {
            // Переключение вкладки — не закрытие: передачи и правки файлов останавливаются, только когда вкладки
            // «Файлы» этого хоста больше нет (или закрыто отдельное окно).
            let alias = host.alias
            let queue = queue, edits = edits
            Task { @MainActor in
                if embedded {
                    try? await Task.sleep(for: .milliseconds(300))
                    let open = model.sessions.contains { if case .files(let h) = $0.kind { return h.alias == alias }; return false }
                    if open { return }
                }
                queue.cancelAll()
                edits.forEach { $0.stop() }
            }
        }
        .alert(L("Переименовать"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Имя"), text: $renameText)
            Button(L("Переименовать")) {
                guard let f = renaming, !renameText.isEmpty, renameText != f.name else { return }
                let base = path, newName = renameText
                perform(L("Переименовываю…")) {
                    try await client.rename(SFTPClient.join(base, f.name), to: SFTPClient.join(base, newName))
                }
            }
            Button(L("Отмена"), role: .cancel) {}
        }
        .alert(L("Новая папка"), isPresented: $newFolder) {
            TextField(L("Имя"), text: $newFolderName)
            Button(L("Создать")) { perform(L("Создаю папку…")) { try await client.makeDirectory(SFTPClient.join(path, newFolderName)) } }
            Button(L("Отмена"), role: .cancel) {}
        }
        .confirmationDialog(L("Удалить %@ объект(ов) на сервере?", "\(selectedFiles.count)"), isPresented: $confirmDelete) {
            Button(L("Удалить"), role: .destructive) {
                let targets = selectedFiles
                perform(L("Удаляю…")) {
                    for f in targets { try await client.remove(SFTPClient.join(path, f.name), isDirectory: f.isDirectory) }
                }
            }
        } message: {
            Text(L("Папки удаляются, только если они пустые. Восстановить файлы будет нельзя."))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(Theme.tx2)
            Text(host.alias).fontWeight(.semibold)
            IconButton(systemImage: "chevron.up", label: L("Наверх")) { open(SFTPClient.parent(of: path)) }
                .disabled(path == "/" || path.isEmpty)
                .keyboardShortcut(.upArrow, modifiers: .command)
            TextField(L("Путь"), text: $pathField)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .onSubmit { open(pathField) }
            IconButton(systemImage: "arrow.clockwise", label: L("Обновить")) { open(path) }
                .keyboardShortcut("r", modifiers: .command)
            if model.finderMounting.contains(host.alias) {
                ProgressView().controlSize(.small)
            } else if model.finderBridges[host.alias] != nil {
                Button(L("Отключить диск")) { model.ejectFinder(host) }.buttonStyle(.relaya)
                    .help(L("Отключить диск хоста в Finder"))
            } else {
                Button(L("Открыть в Finder…")) { model.finderMountRequest = host }.buttonStyle(.relaya)
                    .help(L("Подключить файлы хоста как диск в Finder"))
            }
            Button(L("Загрузить…")) { chooseUpload() }.buttonStyle(.relaya)
            Button(L("Скачать…")) { download() }.buttonStyle(.relaya).disabled(selection.isEmpty)
            IconButton(systemImage: "folder.badge.plus", label: L("Новая папка")) { newFolderName = ""; newFolder = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
            if !embedded {
                Button(L("Готово")) { dismiss() }.buttonStyle(.relayaPrimary).keyboardShortcut(.cancelAction)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    /// Скрытые кнопки для сочетаний без видимого элемента.
    private var shortcuts: some View {
        Group {
            Button("") { if !selection.isEmpty { confirmDelete = true } }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                Text(error).foregroundStyle(Theme.red).lineLimit(2).textSelection(.enabled)
            } else if !edits.isEmpty {
                Image(systemName: "pencil.circle").foregroundStyle(Theme.acc)
                Text(L("Открыто в редакторе: %@ · сохранения загружаются на сервер", "\(edits.count)")).foregroundStyle(Theme.tx2)
            } else {
                Text(L("%@ объектов · перетащите файлы из Finder, чтобы загрузить сюда", "\(files.count)")).foregroundStyle(Theme.tx2)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    // MARK: - Действия

    private func start() async {
        if !host.usesKey, model.keychain.hasPassword(for: host.keychainAccount),
           !(await SecretGate.shared.authorize(L("Открыть файлы на %@", host.alias))) {
            error = L("Touch ID не подтверждён — пароль из Keychain не использован.")
            return
        }
        queue.onFinish = { item in
            if item.upload { Task { await load(path) } }
        }
        loading = true
        do {
            let home = try await client.home()
            await load(home)
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func open(_ target: String) {
        Task { await load(target) }
    }

    private func load(_ target: String) async {
        loading = true
        error = nil
        do {
            files = try await client.list(target)
            path = target
            pathField = target
            selection = []
        } catch {
            self.error = error.localizedDescription
            pathField = path
        }
        loading = false
    }

    /// Выполняет операцию с индикатором и перечитывает папку.
    private func perform(_ label: String, _ op: @escaping @MainActor () async throws -> Void) {
        Task {
            busy = label
            error = nil
            var failure: String?
            do { try await op() } catch { failure = error.localizedDescription }
            busy = nil
            await load(path)
            // Ошибка операции важнее: обновление списка её не стирает.
            if let failure { error = failure }
        }
    }

    private func download() {
        let targets = selectedFiles
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Скачать сюда")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = path
        Task {
            let ssh = await sshInvocation()
            let sftp = client
            for f in targets {
                let remote = SFTPClient.join(base, f.name)
                let local = dir.appending(path: f.name)
                if f.isDirectory {
                    queue.enqueue(name: f.name, upload: false, total: nil) { _ in
                        try await sftp.download(remote, to: dir, recursive: true)
                    }
                } else {
                    queue.enqueue(name: f.name, upload: false, total: f.size) { progress in
                        try await StreamTransfer.download(ssh, remotePath: remote, to: local, progress: progress)
                    }
                }
            }
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Загрузить")
        guard panel.runModal() == .OK else { return }
        upload(urls: panel.urls)
    }

    private func upload(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let base = path
        Task {
            let ssh = await sshInvocation()
            let sftp = client
            for url in urls {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = url.lastPathComponent
                if isDir {
                    queue.enqueue(name: name, upload: true, total: nil) { _ in try await sftp.upload(url.path, to: base) }
                } else {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                    queue.enqueue(name: name, upload: true, total: size) { progress in
                        try await StreamTransfer.upload(ssh, localURL: url, remoteDirectory: base, name: name, progress: progress)
                    }
                }
            }
        }
    }

    private func sshInvocation() async -> SSHInvocation {
        await model.invocation(for: host, interactive: false, reason: L("Открыть файлы на %@", host.alias))
    }

    /// Скачать во временную папку, открыть в редакторе по умолчанию и загружать каждое сохранение.
    private func edit(_ f: RemoteFile) {
        let base = path
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "Relaya-edit").appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appending(path: f.name)
        let remote = SFTPClient.join(base, f.name)
        Task {
            let ssh = await sshInvocation()
            do {
                try await StreamTransfer.download(ssh, remotePath: remote, to: local) { _ in }
            } catch {
                self.error = error.localizedDescription
                return
            }
            let session = RemoteEditSession(remoteDirectory: base, name: f.name, localURL: local)
            session.watch {
                let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                queue.enqueue(name: f.name, upload: true, total: size) { progress in
                    try await StreamTransfer.upload(ssh, localURL: local, remoteDirectory: base, name: f.name, progress: progress)
                }
            }
            edits.append(session)
            NSWorkspace.shared.open(local)
        }
    }
}

/// Список передач над строкой состояния.
private struct TransferList: View {
    let queue: TransferQueue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Передачи")).font(.system(size: 12, weight: .semibold))
                Spacer()
                if queue.hasFinished {
                    Button(L("Очистить")) { queue.clearFinished() }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queue.items) { item in row(item) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 150)
        }
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private func row(_ item: TransferQueue.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.upload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(Theme.tx2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(detail(item)).foregroundStyle(stateColor(item.state)).lineLimit(1)
                }
                if item.state == .running {
                    if let f = item.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
            switch item.state {
            case .queued, .running:
                IconButton(systemImage: "xmark.circle", label: L("Отменить")) { queue.cancel(item.id) }
            case .failed, .cancelled:
                IconButton(systemImage: "arrow.clockwise", label: L("Повторить")) { queue.retry(item.id) }
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.grn)
            }
        }
        .font(.system(size: 12))
    }

    private func detail(_ item: TransferQueue.Item) -> String {
        let done = ByteCountFormatter.string(fromByteCount: item.transferred, countStyle: .file)
        switch item.state {
        case .queued: return L("В очереди")
        case .cancelled: return L("Отменено")
        case .failed(let message): return message
        case .done:
            return item.total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L("Готово")
        case .running:
            var parts = [item.total.map { "\(done) / " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? done]
            if let f = item.fraction { parts.insert("\(Int(f * 100))%", at: 0) }
            if let s = item.speed { parts.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) + L("/с")) }
            return parts.joined(separator: " · ")
        }
    }

    private func stateColor(_ state: TransferQueue.State) -> Color {
        if case .failed = state { return Theme.red }
        return Theme.tx2
    }
}
