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

    private var client: SFTPClient {
        let usePassword = !host.usesKey && model.keychain.hasPassword(for: host.keychainAccount)
        return SFTPClient(alias: host.alias,
                          password: usePassword ? .init(store: model.keychain, account: host.keychainAccount, kind: .password) : nil,
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
            .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
                if !ids.isEmpty {
                    Button(L("Скачать…")) { download() }
                    Button(L("Удалить…"), role: .destructive) { confirmDelete = true }
                }
            } primaryAction: { ids in
                if ids.count == 1, let f = files.first(where: { ids.contains($0.id) }), f.isDirectory || f.isLink {
                    open(SFTPClient.join(path, f.name))
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
            statusBar
        }
        .frame(width: embedded ? nil : 860, height: embedded ? nil : 560)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Theme.bg)
        .task { await start() }
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
            TextField(L("Путь"), text: $pathField)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .onSubmit { open(pathField) }
            IconButton(systemImage: "arrow.clockwise", label: L("Обновить")) { open(path) }
            Button(L("Загрузить…")) { chooseUpload() }.buttonStyle(.relaya)
            Button(L("Скачать…")) { download() }.buttonStyle(.relaya).disabled(selection.isEmpty)
            IconButton(systemImage: "folder.badge.plus", label: L("Новая папка")) { newFolderName = ""; newFolder = true }
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

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                Text(error).foregroundStyle(Theme.red).lineLimit(2).textSelection(.enabled)
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
            do { try await op() } catch { self.error = error.localizedDescription }
            busy = nil
            await load(path)
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
        perform(L("Скачиваю %@ объект(ов)…", "\(targets.count)")) {
            for f in targets {
                try await client.download(SFTPClient.join(base, f.name), to: dir, recursive: f.isDirectory)
            }
            NSWorkspace.shared.activateFileViewerSelecting(targets.map { dir.appending(path: $0.name) })
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
        perform(L("Загружаю %@ объект(ов)…", "\(urls.count)")) {
            for url in urls { try await client.upload(url.path, to: base) }
        }
    }
}
