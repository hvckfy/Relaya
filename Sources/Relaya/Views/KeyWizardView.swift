import SwiftUI
import RelayaCore

/// Мастер «Настроить вход по ключу» (docs/design/KeyWizard1–4, UI_SPEC 3.6).
///
/// Порядок применения: ключ → сервер → агент → проверка → ~/.ssh/config.
/// Config меняется последним, только после успешного проверочного входа.
@MainActor
@Observable
final class KeyWizardModel {
    enum Step: Int, CaseIterable { case key, preview, apply, done }
    enum Mode { case new, existing }
    enum Status { case pending, running, ok, failed, skipped }

    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    let host: SSHHost
    let model: AppModel

    var step: Step = .key
    var mode: Mode = .new
    var fileName: String
    var comment: String
    var passphrase = ""
    var existingPath = ""
    var existingPassphrase = ""
    var serverPassword = ""
    var saveServerPassword = true
    var keys: [SSHKey] = []
    let hasSavedPassword: Bool

    var statuses: [String: Status] = [:]
    var log: [LogLine] = []
    var error: String?
    var rollbackNote: String?
    var result: SSHKey?
    var running = false
    /// Выбор на последнем шаге. По умолчанию вход по паролю не трогаем.
    var passwordLogin = true

    static let applySteps = ["Ключ", "Сервер", "Агент", "Проверка", "Config"]

    init(host: SSHHost, model: AppModel) {
        self.host = host
        self.model = model
        fileName = "id_ed25519_\(host.alias)"
        comment = "\(NSUserName())@\(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "mac") · \(host.alias)"
        hasSavedPassword = model.keychain.hasPassword(for: host.keychainAccount)
    }

    func loadKeys() async {
        keys = await KeyScanner.scan()
        if existingPath.isEmpty { existingPath = keys.first?.path ?? "" }
    }

    var keyPath: String {
        mode == .new ? SSHPaths.sshDirectory.appending(path: fileName).path : existingPath
    }

    var existingKey: SSHKey? { keys.first { $0.path == existingPath } }

    var keyError: String? {
        switch mode {
        case .new:
            if fileName.isEmpty || fileName.contains("/") { return "Имя файла без «/»" }
            if FileManager.default.fileExists(atPath: keyPath) { return "Файл уже есть — выберите «Использовать существующий»" }
        case .existing:
            if existingKey == nil { return "Выберите ключ" }
        }
        return nil
    }

    var configDiff: [LineDiff.Line] {
        guard let doc = try? model.store.loadDocument() else { return [] }
        var updated = host
        updated.identityFile = SSHPaths.abbreviate(keyPath)
        return LineDiff.diff(doc.currentLines(for: host.alias), doc.renderedLines(for: updated, replacing: host.alias))
    }

    var serverLine: String {
        if mode == .existing, let k = existingKey { return k.publicKey }
        return "ssh-ed25519 AAAA…(будет создан) \(comment)"
    }

    // MARK: - Применение

    func apply() async {
        running = true
        error = nil
        rollbackNote = nil
        log = []
        statuses = Dictionary(uniqueKeysWithValues: Self.applySteps.map { ($0, Status.pending) })
        step = .apply

        let installer = KeyInstaller(askpassExecutable: model.askpassExecutable)
        let temp = KeyInstaller.temporaryKeychain
        var tempAccounts: [String] = []
        var createdKey = false
        defer {
            for a in tempAccounts { try? temp.deletePassword(for: a) }
            running = false
        }

        func run(_ name: String, _ body: () async throws -> Void) async throws {
            statuses[name] = .running
            do {
                try await body()
                statuses[name] = .ok
            } catch {
                statuses[name] = .failed
                throw error
            }
        }

        do {
            // 1. Ключ
            if mode == .new {
                try await run("Ключ") {
                    note("ssh-keygen -t ed25519 -f \(SSHPaths.abbreviate(keyPath))")
                    try await installer.generate(path: keyPath, comment: comment, passphrase: passphrase)
                    createdKey = true
                }
            } else {
                statuses["Ключ"] = .skipped
            }
            guard let pub = try? String(contentsOfFile: keyPath + ".pub", encoding: .utf8) else {
                throw KeyInstaller.Failure("Не найден \(SSHPaths.abbreviate(keyPath)).pub")
            }

            // 2. Сервер
            try await run("Сервер") {
                var secret: KeyInstaller.SecretRef?
                if hasSavedPassword {
                    secret = .init(store: model.keychain, account: host.keychainAccount, kind: .password)
                } else if !serverPassword.isEmpty {
                    if saveServerPassword {
                        try model.keychain.setPassword(serverPassword, for: host.keychainAccount)
                        secret = .init(store: model.keychain, account: host.keychainAccount, kind: .password)
                        note("пароль сервера сохранён в Keychain")
                    } else {
                        let a = UUID().uuidString
                        try temp.setPassword(serverPassword, for: a)
                        tempAccounts.append(a)
                        secret = .init(store: temp, account: a, kind: .password)
                    }
                }
                note("append ~/.ssh/authorized_keys on \(host.alias)")
                try await installer.install(publicKey: pub.trimmingCharacters(in: .whitespacesAndNewlines),
                                            alias: host.alias, password: secret)
            }

            // 3. Агент + passphrase в системный Keychain
            let phrase = mode == .new ? passphrase : existingPassphrase
            if !phrase.isEmpty {
                try await run("Агент") {
                    let a = UUID().uuidString
                    try temp.setPassword(phrase, for: a)
                    tempAccounts.append(a)
                    note("ssh-add --apple-use-keychain \(SSHPaths.abbreviate(keyPath))")
                    try await installer.addToAgent(keyPath: keyPath, passphrase: .init(store: temp, account: a, kind: .passphrase))
                }
            } else {
                statuses["Агент"] = .skipped
            }

            // 4. Проверка
            try await run("Проверка") {
                note("ssh -o BatchMode=yes -i \(SSHPaths.abbreviate(keyPath)) \(host.alias) true")
                try await installer.verify(alias: host.alias, keyPath: keyPath)
            }

            // 5. Config
            try await run("Config") {
                var updated = host
                updated.identityFile = SSHPaths.abbreviate(keyPath)
                note("backup ~/.ssh/config → ~/.ssh/config.bak")
                try model.save(updated, originalAlias: host.alias)
            }

            result = await KeyScanner.inspect(path: keyPath)
            await model.detectOS(for: host.alias)
            step = .done
        } catch {
            self.error = error.localizedDescription
            var undone: [String] = []
            if createdKey {
                try? FileManager.default.removeItem(atPath: keyPath)
                try? FileManager.default.removeItem(atPath: keyPath + ".pub")
                undone.append("удалены созданные файлы \(fileName)*")
            }
            let serverChanged = statuses["Сервер"] == .ok
            undone.append(serverChanged
                ? "ключ на сервере остался в authorized_keys — удалите строку вручную, если она не нужна"
                : "на сервере ничего не изменено")
            undone.append("~/.ssh/config не менялся")
            rollbackNote = undone.joined(separator: "; ")
        }
    }

    private func note(_ text: String) {
        log.append(LogLine(text: text))
    }
}

struct KeyWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var wizard: KeyWizardModel

    init(host: SSHHost, model: AppModel) {
        _wizard = State(initialValue: KeyWizardModel(host: host, model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch wizard.step {
                    case .key: KeyStep(wizard: wizard)
                    case .preview: PreviewStep(wizard: wizard)
                    case .apply: ApplyStep(wizard: wizard)
                    case .done: DoneStep(wizard: wizard)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            footer
        }
        .frame(width: 640, height: 640)
        .background(Theme.bg)
        .task { await wizard.loadKeys() }
        .interactiveDismissDisabled(wizard.running)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Настроить вход по ключу").font(.system(size: 17, weight: .bold))
                Spacer()
                Text("Хост \(wizard.host.subtitle)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.tx2)
            }
            HStack(spacing: 6) {
                ForEach(KeyWizardModel.Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= wizard.step.rawValue ? Theme.accBg : Theme.sel)
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch wizard.step {
            case .key:
                Button("Отмена") { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button("Далее") { wizard.step = .preview }
                    .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
                    .disabled(wizard.keyError != nil)
            case .preview:
                Button("Отмена") { dismiss() }.buttonStyle(.relaya).keyboardShortcut(.cancelAction)
                Button("Назад") { wizard.step = .key }.buttonStyle(.relaya)
                Button("Применить") { Task { await wizard.apply() } }
                    .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
            case .apply:
                Button("Отмена") { dismiss() }.buttonStyle(.relaya).disabled(wizard.running)
                Button("Назад") { wizard.step = .key }.buttonStyle(.relaya).disabled(wizard.running)
                Button("Повторить") { Task { await wizard.apply() } }
                    .buttonStyle(.relayaPrimary).disabled(wizard.running)
            case .done:
                Button("Готово") {
                    if !wizard.passwordLogin {
                        let host = wizard.model.current(wizard.host)
                        wizard.model.run((host.os ?? .linux).passwordLoginCommand(enabled: false), on: host)
                    }
                    dismiss()
                }
                .buttonStyle(.relayaPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

// MARK: - Шаги

private struct KeyStep: View {
    @Bindable var wizard: KeyWizardModel

    var body: some View {
        Section2(title: "Ключ") {
            Picker("", selection: $wizard.mode) {
                Text("Создать новый ed25519 — рекомендуется").tag(KeyWizardModel.Mode.new)
                Text("Использовать существующий").tag(KeyWizardModel.Mode.existing)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if wizard.mode == .new {
                Field("Имя файла") {
                    HStack(spacing: 2) {
                        Text("~/.ssh/").foregroundStyle(Theme.tx2)
                        TextField("", text: $wizard.fileName).textFieldStyle(.roundedBorder)
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                }
                Field("Комментарий") { TextField("", text: $wizard.comment).textFieldStyle(.roundedBorder) }
                Field("Passphrase") {
                    SecureField("необязательно", text: $wizard.passphrase).textFieldStyle(.roundedBorder)
                }
                if !wizard.passphrase.isEmpty {
                    Text("Passphrase будет сохранена в Keychain macOS (UseKeychain), вводить её не придётся.")
                        .font(.system(size: 12)).foregroundStyle(Theme.tx2)
                }
            } else {
                Field("Ключ") {
                    Picker("", selection: $wizard.existingPath) {
                        ForEach(wizard.keys) { k in
                            Text("\(k.name) · \(k.type)").tag(k.path)
                        }
                    }
                    .labelsHidden()
                }
                if wizard.existingKey?.hasPassphrase == true {
                    Field("Passphrase ключа") {
                        SecureField("для ssh-agent", text: $wizard.existingPassphrase).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }

        Section2(title: "Доступ к серверу") {
            if wizard.hasSavedPassword {
                Text("Пароль сервера возьмём из Keychain.").foregroundStyle(Theme.tx2)
            } else {
                Field("Пароль сервера") {
                    SecureField("если вход по паролю", text: $wizard.serverPassword).textFieldStyle(.roundedBorder)
                }
                Toggle("Сохранить пароль в Keychain", isOn: $wizard.saveServerPassword)
                    .disabled(wizard.serverPassword.isEmpty)
            }
        }

        if let e = wizard.keyError {
            Text(e).font(.system(size: 12)).foregroundStyle(Theme.red)
        }
        Text("На следующем шаге покажем все изменения до того, как что-то будет записано.")
            .font(.system(size: 12)).foregroundStyle(Theme.tx2)
    }
}

private struct PreviewStep: View {
    let wizard: KeyWizardModel

    var body: some View {
        Text("Вот что изменится. Ничего не записано, пока вы не нажмёте «Применить».")
            .foregroundStyle(Theme.tx2)

        if wizard.mode == .new {
            ChangeBlock(title: "Локально", detail: "~/.ssh/", badge: "+2 файла") {
                CodeLine(kind: .added, text: "\(wizard.fileName)        600 -rw-------")
                CodeLine(kind: .added, text: "\(wizard.fileName).pub    644 -rw-r--r--")
            }
        }
        ChangeBlock(title: "Config", detail: "~/.ssh/config", badge: "бэкап → config.bak") {
            ForEach(Array(wizard.configDiff.enumerated()), id: \.offset) { _, l in
                CodeLine(kind: l.kind, text: l.text)
            }
        }
        ChangeBlock(title: "Сервер", detail: "\(wizard.host.alias):~/.ssh/authorized_keys", badge: "+1 строка") {
            CodeLine(kind: .added, text: wizard.serverLine)
        }
    }
}

private struct ApplyStep: View {
    let wizard: KeyWizardModel
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(KeyWizardModel.applySteps, id: \.self) { name in
                HStack(spacing: 10) {
                    icon(wizard.statuses[name] ?? .pending)
                        .frame(width: 18)
                    Text(label(name))
                        .foregroundStyle(wizard.statuses[name] == .skipped ? Theme.tx2 : Theme.tx)
                }
            }
        }

        if let error = wizard.error {
            BannerRow(tint: Theme.redTint, border: Theme.red) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                    if let note = wizard.rollbackNote {
                        Text("Откатили: \(note).").fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        DisclosureGroup("Показать лог", isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(wizard.log) { line in
                    Text("\(line.time.formatted(date: .omitted, time: .standard))  \(line.text)")
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Theme.tx2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ name: String) -> String {
        switch name {
        case "Ключ": "Ключ создан"
        case "Сервер": "Ключ добавлен на сервер"
        case "Агент": "Passphrase в Keychain, ключ в ssh-agent"
        case "Проверка": "Проверочный вход по ключу"
        default: "~/.ssh/config обновлён (бэкап config.bak)"
        }
    }

    @ViewBuilder private func icon(_ s: KeyWizardModel.Status) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(Theme.tx2)
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.grn)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.tx2)
        }
    }
}

private struct DoneStep: View {
    @Bindable var wizard: KeyWizardModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(Theme.grn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Теперь вход по ключу").font(.system(size: 17, weight: .bold))
                Text("Проверочное подключение без пароля прошло успешно.").foregroundStyle(Theme.tx2)
            }
        }

        Section2(title: "Итог") {
            Field("Ключ") { Mono(SSHPaths.abbreviate(wizard.keyPath)) }
            Field("Отпечаток") { Mono(wizard.result?.fingerprint ?? "—") }
            Field("Passphrase") { Mono(wizard.result?.hasPassphrase == true ? "в Keychain" : "нет") }
            Field("Бэкап config") { Mono("~/.ssh/config.bak") }
        }

        Section2(title: "Вход по паролю на сервере") {
            Picker("", selection: $wizard.passwordLogin) {
                Text("Включён — можно входить и по паролю, и по ключу").tag(true)
                Text("Отключён — только по ключу").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(wizard.passwordLogin
                 ? "На сервере ничего не меняем."
                 : "После «Готово» откроется вкладка терминала и выполнит команду на сервере. Если ключ потеряется, а консоли провайдера нет — войти будет нельзя. Вернуть вход по паролю: меню «Действия» в сессии.")
                .font(.system(size: 12))
                .foregroundStyle(wizard.passwordLogin ? Theme.tx2 : Theme.org)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Мелкие элементы

private struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tx2)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bg2, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5))
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 140, alignment: .leading)
            content
        }
    }
}

private struct Mono: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
    }
}

private struct ChangeBlock<Content: View>: View {
    let title: String
    let detail: String
    let badge: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).fontWeight(.bold)
                Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tx2)
                Spacer()
                Text(badge).font(.system(size: 11)).foregroundStyle(Theme.grn)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(Theme.line2)
            VStack(alignment: .leading, spacing: 0) { content }.padding(.vertical, 6)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tx)
        .background(Theme.bg2, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

struct CodeLine: View {
    let kind: LineDiff.Kind
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Text(kind == .added ? "+" : kind == .removed ? "−" : " ")
                .frame(width: 22)
                .foregroundStyle(kind == .added ? Theme.grn : kind == .removed ? Theme.red : Theme.tx2)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(kind == .same ? Theme.tx2 : Theme.tx)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(kind == .added ? Theme.grnTint : kind == .removed ? Theme.redTint : .clear)
        .textSelection(.enabled)
    }
}
