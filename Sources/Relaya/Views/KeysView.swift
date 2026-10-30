import SwiftUI
import RelayaCore

/// Экран «Ключи» (docs/design/Keys, UI_SPEC 3.7): пары ключей из ~/.ssh и инспектор.
struct KeysView: View {
    @Environment(AppModel.self) private var model
    @State private var keys: [SSHKey] = []
    @State private var inAgent: Set<String> = []
    @State private var selection: SSHKey.ID?
    @State private var loading = true
    @State private var generate = false
    @State private var deploy: SSHKey?
    @State private var confirmDelete: SSHKey?
    @State private var askPassphrase: SSHKey?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("Ключи")).font(.system(size: 15, weight: .bold))
                Text("~/.ssh · \(keys.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
                Spacer()
                Button(L("Сгенерировать…")) { generate = true }.buttonStyle(.relayaPrimary)
                Button(L("Показать в Finder")) {
                    NSWorkspace.shared.open(SSHPaths.sshDirectory)
                }
                .buttonStyle(.relaya)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }

            HStack(spacing: 0) {
                keysTable
                .overlay {
                    if loading { ProgressView() }
                    else if keys.isEmpty {
                        VStack(spacing: 8) {
                            Text(L("В ~/.ssh нет ключей")).foregroundStyle(Theme.tx2)
                            Button(L("Сгенерировать ed25519")) { generate = true }.buttonStyle(.relayaPrimary)
                        }
                    }
                }

                if let key = keys.first(where: { $0.id == selection }) {
                    Rectangle().fill(Theme.line).frame(width: 0.5)
                    inspector(key)
                        .frame(width: 320)
                }
            }
        }
        .background(Theme.bg)
        .task { await reload() }
        .sheet(isPresented: $generate) {
            GenerateKeySheet { path in
                Task {
                    await reload()
                    selection = path
                }
            }
        }
        .sheet(item: $deploy) { key in
            DeployKeySheet(key: key) { Task { await reload() } }
                .environment(model)
        }
        .sheet(item: $askPassphrase) { key in
            PasswordSheet(title: L("Passphrase для %@", "\(key.name)"), saveLabel: L("Сохранить в Keychain macOS")) { phrase, _ in
                Task { await addToAgent(key, passphrase: phrase) }
            }
        }
        .confirmationDialog(L("Переместить %@ в Корзину?", "\(confirmDelete?.name ?? "")"),
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { key in
            Button(L("В Корзину"), role: .destructive) { trash(key) }
        } message: { key in
            let names = hosts(using: key).map(\.alias)
            Text(names.isEmpty
                 ? L("Ключ не указан ни у одного хоста в ~/.ssh/config. Файлы можно будет восстановить из Корзины.")
                 : L("Перестанут подключаться по этому ключу: %@. Файлы можно будет восстановить из Корзины.", "\(names.joined(separator: ", "))"))
        }
        .alert(L("Ключи"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    // Отдельно от body: иначе компилятор не успевает вывести типы всего экрана.
    private var keysTable: some View {
        Table(keys, selection: $selection) {
            TableColumn(L("Имя файла")) { (k: SSHKey) in Text(k.name).font(.system(size: 12.5, design: .monospaced)) }
            TableColumn(L("Тип")) { (k: SSHKey) in Text(k.type) }.width(70)
            TableColumn(L("Отпечаток")) { (k: SSHKey) in
                Text(k.fingerprint).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Passphrase") { (k: SSHKey) in Text(k.hasPassphrase ? L("да") : L("нет")) }.width(80)
            TableColumn(L("В агенте ⓘ")) { (k: SSHKey) in AgentCell(inAgent: inAgent.contains(k.fingerprint)) }.width(80)
            TableColumn(L("Хосты")) { (k: SSHKey) in Text("\(hosts(using: k).count)") }.width(50)
        }
        // Заголовки Table не показывают свои подсказки — даём её всей таблице, ячейкам «В агенте» — свою.
        .help(Self.agentHelp)
    }

    private func inspector(_ key: SSHKey) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.name).font(.system(size: 15, weight: .bold))
                    Text([key.type,
                          key.created.map { L("создан %@", "\($0.formatted(date: .abbreviated, time: .omitted))") },
                          key.hasPassphrase ? L("с passphrase") : L("без passphrase")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.tx2)
                }

                caption(L("Публичный ключ")) {
                    Button(L("Копировать")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key.publicKey, forType: .string)
                    }
                    .buttonStyle(.relaya(.ghost, height: 22))
                }
                Text(key.publicKey)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg2, in: .rect(cornerRadius: 8, style: .continuous))

                caption(L("Отпечаток")) { EmptyView() }
                Text(key.fingerprint).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)

                let using = hosts(using: key)
                caption(L("Используется хостами · %@", "\(using.count)")) { EmptyView() }
                if using.isEmpty {
                    Text(L("Ни один хост не указывает этот ключ в IdentityFile."))
                        .font(.system(size: 12)).foregroundStyle(Theme.tx2)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(using) { h in
                            Text("\(h.alias)  ").font(.system(size: 12.5)) + Text(h.subtitle).font(.system(size: 11)).foregroundColor(Theme.tx2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button(L("Разложить на хосты…")) { deploy = key }.buttonStyle(.relayaPrimary)
                    HStack(spacing: 6) {
                        if inAgent.contains(key.fingerprint) {
                            Label(L("В агенте"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.grn)
                                .help(Self.agentHelp)
                            Button(L("Убрать из агента")) { Task { await removeFromAgent(key) } }
                                .buttonStyle(.relaya)
                                .help(L("ssh-add -d: выгрузить ключ из памяти ssh-agent. Файлы ключа и passphrase в Keychain остаются."))
                        } else {
                            Button(L("Добавить в агент")) {
                                if key.hasPassphrase { askPassphrase = key } else { Task { await addToAgent(key, passphrase: nil) } }
                            }
                            .buttonStyle(.relaya)
                            .help(Self.agentHelp)
                        }
                    }
                    Button(L("В Корзину…"), role: .destructive) { confirmDelete = key }.buttonStyle(.relaya(.ghost))
                }
                Text(L("При удалении покажем, какие хосты перестанут подключаться."))
                    .font(.system(size: 11)).foregroundStyle(Theme.tx2)
            }
            .padding(16)
        }
        .foregroundStyle(Theme.tx)
        .font(.system(size: 13))
    }

    private func caption<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx2)
            Spacer()
            trailing()
        }
    }

    private func hosts(using key: SSHKey) -> [SSHHost] {
        model.hosts.filter { h in h.identityFile.map(SSHPaths.expand) == key.path }
    }

    private func reload() async {
        loading = true
        keys = await KeyScanner.scan()
        inAgent = await KeyScanner.agentFingerprints()
        loading = false
        if selection == nil { selection = keys.first?.id }
    }

    static let agentHelp = L("""
    ssh-agent — системная служба macOS, которая держит ключи расшифрованными в памяти.
    Ключ «в агенте»: ssh использует его без ввода passphrase (она сохраняется в Keychain), и его можно пробросить на сервер через ForwardAgent.
    Минус: если в агенте много ключей, ssh перебирает их все, и сервер может оборвать вход («Too many authentication failures») раньше, чем спросит пароль.
    """)

    private func removeFromAgent(_ key: SSHKey) async {
        do {
            try await KeyInstaller(askpassExecutable: model.askpassExecutable).removeFromAgent(keyPath: key.path)
            inAgent = await KeyScanner.agentFingerprints()
        } catch {
            message = error.localizedDescription
        }
    }

    private func addToAgent(_ key: SSHKey, passphrase: String?) async {
        let installer = KeyInstaller(askpassExecutable: model.askpassExecutable)
        let temp = KeyInstaller.temporaryKeychain
        let account = UUID().uuidString
        defer { try? temp.deletePassword(for: account) }
        do {
            var ref: KeyInstaller.SecretRef?
            if let passphrase {
                try temp.setPassword(passphrase, for: account)
                ref = .init(store: temp, account: account, kind: .passphrase)
            }
            try await installer.addToAgent(keyPath: key.path, passphrase: ref)
            inAgent = await KeyScanner.agentFingerprints()
        } catch {
            message = error.localizedDescription
        }
    }

    private func trash(_ key: SSHKey) {
        do {
            for path in [key.path, key.path + ".pub"] {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            selection = nil
            Task { await reload() }
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct AgentCell: View {
    let inAgent: Bool

    var body: some View {
        Text(inAgent ? L("да") : L("нет"))
            .foregroundStyle(inAgent ? Theme.grn : Theme.tx2)
            .help(KeysView.agentHelp)
    }
}

/// «Сгенерировать…» на экране ключей.
private struct GenerateKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let created: (String) -> Void
    @State private var name = "id_ed25519"
    @State private var comment = "\(NSUserName())@\(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "mac")"
    @State private var passphrase = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Новый ключ ed25519")).font(.system(size: 15, weight: .bold))
            LabeledContent(L("Имя файла")) {
                HStack(spacing: 2) {
                    Text("~/.ssh/").foregroundStyle(Theme.tx2)
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                .font(.system(size: 12.5, design: .monospaced))
            }
            LabeledContent(L("Комментарий")) { TextField("", text: $comment).textFieldStyle(.roundedBorder).frame(width: 260) }
            LabeledContent("Passphrase") {
                SecureField(L("необязательно"), text: $passphrase).textFieldStyle(.roundedBorder).frame(width: 260)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button(L("Создать")) { Task { await create() } }
                    .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || name.contains("/") || working)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.bg)
    }

    private func create() async {
        working = true
        defer { working = false }
        let path = SSHPaths.sshDirectory.appending(path: name).path
        let installer = KeyInstaller(askpassExecutable: model.askpassExecutable)
        do {
            try await installer.generate(path: path, comment: comment, passphrase: passphrase)
            if !passphrase.isEmpty {
                let temp = KeyInstaller.temporaryKeychain
                let account = UUID().uuidString
                defer { try? temp.deletePassword(for: account) }
                try temp.setPassword(passphrase, for: account)
                try await installer.addToAgent(keyPath: path, passphrase: .init(store: temp, account: account, kind: .passphrase))
            }
            created(path)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// «Разложить на хосты…»: публичный ключ → authorized_keys выбранных хостов (+ IdentityFile в config).
private struct DeployKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: SSHKey
    let done: () -> Void

    enum Result { case running, ok, failed(String) }
    @State private var chosen: Set<String> = []
    @State private var writeConfig = true
    @State private var results: [String: Result] = [:]
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Разложить %@ на хосты", "\(key.name)")).font(.system(size: 15, weight: .bold))
            Text(L("Ключ добавится в ~/.ssh/authorized_keys на сервере. Для входа используется сохранённый в Keychain пароль или уже настроенный ключ."))
                .font(.system(size: 12)).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
            List(model.hosts) { h in
                HStack {
                    Toggle(isOn: Binding(get: { chosen.contains(h.alias) },
                                         set: { if $0 { chosen.insert(h.alias) } else { chosen.remove(h.alias) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.alias)
                            Text(h.subtitle).font(.system(size: 11)).foregroundStyle(Theme.tx2)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(working)
                    Spacer()
                    switch results[h.alias] {
                    case .running?: ProgressView().controlSize(.small)
                    case .ok?: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.grn)
                    case .failed(let m)?: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red).help(m)
                    case nil: EmptyView()
                    }
                }
            }
            .frame(height: 240)
            Toggle(L("Прописать IdentityFile в ~/.ssh/config (после успешной проверки)"), isOn: $writeConfig)
            failures
            HStack {
                Spacer()
                Button(results.isEmpty ? L("Отмена") : L("Закрыть")) { done(); dismiss() }
                    .buttonStyle(.relaya).keyboardShortcut(.cancelAction).disabled(working)
                Button(L("Разложить")) { Task { await run() } }
                    .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.bg)
    }

    @ViewBuilder private var failures: some View {
        let failed = results.compactMap { alias, r -> String? in
            if case .failed(let m) = r { return "\(alias): \(m)" } else { return nil }
        }
        if !failed.isEmpty {
            Text(failed.sorted().joined(separator: "\n"))
                .font(.system(size: 11.5)).foregroundStyle(Theme.red).textSelection(.enabled)
        }
    }

    private func run() async {
        working = true
        defer { working = false }
        let installer = KeyInstaller(askpassExecutable: model.askpassExecutable)
        for host in model.hosts where chosen.contains(host.alias) {
            results[host.alias] = .running
            do {
                let secret: KeyInstaller.SecretRef? = model.keychain.hasPassword(for: host.keychainAccount)
                    ? .init(store: model.keychain, account: host.keychainAccount, kind: .password) : nil
                try await installer.install(publicKey: key.publicKey, alias: host.alias, password: secret)
                try await installer.verify(alias: host.alias, keyPath: key.path)
                if writeConfig, host.identityFile.map(SSHPaths.expand) != key.path {
                    var updated = host
                    updated.identityFile = key.displayPath
                    try model.save(updated, originalAlias: host.alias)
                }
                results[host.alias] = .ok
            } catch {
                results[host.alias] = .failed(error.localizedDescription)
            }
        }
    }
}
