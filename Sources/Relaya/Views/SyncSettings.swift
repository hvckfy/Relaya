import SwiftUI
import RelayaCore

/// Настройки → Синхронизация: список профилей слева, выбранный профиль справа (как «Учётные записи» в Почте).
struct SyncSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Sync.Profile.ID?
    @State private var passphrase = ""

    var body: some View {
        let sync = model.sync
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(sync.profiles) { p in
                        HStack {
                            stateIcon(sync.state(p))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name)
                                Text(scopeSummary(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(p.id)
                        .opacity(p.enabled ? 1 : 0.5)
                    }
                }
                .listStyle(.sidebar)
                HStack(spacing: 0) {
                    Button { selection = sync.addProfile().id } label: { Image(systemName: "plus") }
                        .help(L("Новый профиль"))
                    Button {
                        if let id = selection { sync.remove(id); selection = sync.profiles.first?.id }
                    } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        .help(L("Удалить профиль"))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 200)
            Divider()
            if let i = sync.profiles.firstIndex(where: { $0.id == selection }) {
                ProfileForm(profile: Binding(get: { sync.profiles[i] }, set: { sync.profiles[i] = $0 }), passphrase: $passphrase)
                    .id(sync.profiles[i].id)
            } else {
                ContentUnavailableView {
                    Label(L("Синхронизация"), systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text(L("Профиль — это ваш git-репозиторий (или папка в iCloud Drive) и набор хостов: все, группы или отдельные хосты. Пароли не синхронизируются никогда."))
                } actions: {
                    Button(L("Новый профиль")) { selection = sync.addProfile().id }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 520)
        .onAppear { selection = selection ?? sync.profiles.first?.id }
    }

    private func scopeSummary(_ p: Sync.Profile) -> String {
        if p.scope.allHosts { return L("все хосты") }
        let n = p.scope.groups.count + p.scope.hosts.count
        return L("групп и хостов: %@", "\(n)")
    }

    @ViewBuilder private func stateIcon(_ s: SyncManager.State) -> some View {
        switch s {
        case .idle: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .syncing: ProgressView().controlSize(.small)
        case .conflict: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private struct ProfileForm: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: Sync.Profile
    @Binding var passphrase: String
    @State private var showConflict = false

    var body: some View {
        let sync = model.sync
        let state = sync.state(profile)
        Form {
            Section {
                TextField(L("Название"), text: $profile.name)
                Toggle(L("Включён"), isOn: $profile.enabled)
                Picker(L("Где хранить"), selection: $profile.backend) {
                    Text(L("Git-репозиторий")).tag(Sync.Backend.git)
                    Text("iCloud Drive").tag(Sync.Backend.iCloud)
                }
                if profile.backend == .git {
                    LabeledContent(L("Репозиторий")) {
                        HStack {
                            TextField("", text: $profile.remote, prompt: Text("git@server:relaya.git"))
                                .labelsHidden()
                            Menu {
                                ForEach(model.hosts) { h in
                                    Button(h.alias) { profile.remote = "\(h.alias):relaya.git" }
                                }
                            } label: { Image(systemName: "server.rack") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .help(L("Взять хост из ~/.ssh/config"))
                        }
                    }
                    Text(L("Любой git: свой сервер по SSH-ключу (`git init --bare relaya.git`), Gitea, GitLab или GitHub. Доступ — вашими ключами из ~/.ssh."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Папка: iCloud Drive/Relaya Sync/%@", profile.name)).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L("Хосты профиля")) {
                Toggle(L("Все хосты"), isOn: $profile.scope.allHosts)
                if !profile.scope.allHosts {
                    ForEach(model.groups, id: \.self) { g in
                        Toggle(isOn: Binding(get: { profile.scope.groups.contains(g) },
                                             set: { if $0 { profile.scope.groups.insert(g) } else { profile.scope.groups.remove(g) } })) {
                            Label(L("Группа «%@»", g), systemImage: "folder")
                        }
                    }
                    DisclosureGroup(L("Отдельные хосты")) {
                        ForEach(model.hosts.filter { !$0.isGitService }) { h in
                            let viaGroup = h.group.map { profile.scope.groups.contains($0) } ?? false
                            Toggle(isOn: Binding(get: { viaGroup || profile.scope.hosts.contains(h.alias) },
                                                 set: { if $0 { profile.scope.hosts.insert(h.alias) } else { profile.scope.hosts.remove(h.alias) } })) {
                                Text(h.alias)
                            }
                            .disabled(viaGroup)
                        }
                    }
                }
            }

            Section(L("Что синхронизировать")) {
                ForEach(Sync.Item.allCases) { item in
                    let hostless = item == .snippets || item == .agents
                    Toggle(item.title, isOn: Binding(get: { profile.items.contains(item) },
                                                     set: { if $0 { profile.items.insert(item) } else { profile.items.remove(item) } }))
                        .disabled(hostless && !profile.scope.allHosts)
                        .help(hostless && !profile.scope.allHosts ? L("Только для профиля «все хосты»") : "")
                }
                if profile.items.contains(.keys) {
                    LabeledContent(L("Пароль ключей")) {
                        HStack {
                            SecureField("", text: $passphrase,
                                        prompt: Text(sync.hasPassphrase ? L("сохранён в Keychain") : L("не задан")))
                                .labelsHidden()
                            Button(L("Сохранить")) { sync.setPassphrase(passphrase); passphrase = "" }
                                .disabled(passphrase.isEmpty)
                        }
                    }
                    Text(L("Ключи шифруются этим паролем до отправки; на другом Mac введите тот же пароль. Существующие ключи с тем же именем не перезаписываются."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Пароли от серверов не синхронизируются никогда. Удаления не передаются: убранный здесь хост на других Mac останется."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("Синхронизировать автоматически (каждые 10 минут и при запуске)"), isOn: $profile.auto)
                LabeledContent(L("Состояние")) {
                    HStack {
                        switch state {
                        case .idle:
                            Text(sync.lastSync(profile).map { L("синхронизировано %@", $0.formatted(.relative(presentation: .named))) }
                                 ?? L("ещё не синхронизировалось")).foregroundStyle(.secondary)
                        case .syncing:
                            ProgressView().controlSize(.small)
                            Text(L("синхронизация…")).foregroundStyle(.secondary)
                        case .conflict(let c):
                            Text(L("конфликт в %@ файлах", "\(c.count)")).foregroundStyle(.orange)
                            Button(L("Разобрать…")) { showConflict = true }
                        case .failed(let m):
                            Text(m).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                        }
                    }
                }
                Button(L("Синхронизировать сейчас")) { Task { await sync.sync(profile.id) } }
                    .disabled(state == .syncing || !profile.enabled)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showConflict) {
            if case .conflict(let c) = state { ConflictSheet(profileID: profile.id, conflicts: c) }
        }
    }
}

/// Конфликт: обе версии файла рядом, выбор по каждому файлу.
struct ConflictSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profileID: Sync.Profile.ID
    let conflicts: [GitSync.Conflict]
    @State private var keepMine: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Конфликт синхронизации")).font(.title3.bold())
            Text(L("Этот файл изменился и здесь, и на другом Mac. Выберите, какую версию оставить; вся история остаётся в репозитории."))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(conflicts) { c in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(c.path).font(.headline.monospaced())
                                Spacer()
                                Picker("", selection: Binding(get: { keepMine[c.path] ?? true }, set: { keepMine[c.path] = $0 })) {
                                    Text(L("Моя версия")).tag(true)
                                    Text(L("С другого Mac")).tag(false)
                                }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                            }
                            HStack(alignment: .top, spacing: 8) {
                                version(L("Моя"), c.mine, chosen: keepMine[c.path] ?? true)
                                version(L("С другого Mac"), c.theirs, chosen: !(keepMine[c.path] ?? true))
                            }
                        }
                    }
                }
            }
            HStack {
                Button(L("Отложить")) { Task { await model.sync.postpone(profileID); dismiss() } }
                Spacer()
                Button(L("Применить")) {
                    let choices = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.path, keepMine[$0.path] ?? true) })
                    Task { await model.sync.resolve(profileID, choices); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 820, height: 560)
    }

    private func version(_ title: String, _ text: String, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                     lineWidth: chosen ? 2 : 0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Кнопка в тулбаре: состояние синхронизации, клик — синхронизировать всё; при конфликте — разобрать.
struct SyncToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var conflict: (Sync.Profile.ID, [GitSync.Conflict])?

    var body: some View {
        let sync = model.sync
        Button {
            if let p = sync.activeProfiles.first(where: { if case .conflict = sync.state($0) { true } else { false } }),
               case .conflict(let c) = sync.state(p) {
                conflict = (p.id, c)
            } else {
                Task { await sync.syncAll() }
            }
        } label: {
            switch sync.overall {
            case .syncing: Label(L("Синхронизация…"), systemImage: "arrow.triangle.2.circlepath.circle")
            case .conflict: Label(L("Конфликт синхронизации"), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            case .failed: Label(L("Ошибка синхронизации"), systemImage: "exclamationmark.icloud")
            case .idle: Label(L("Синхронизировать"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .help({
            switch sync.overall {
            case .failed(let m): return m
            case .conflict: return L("Конфликт синхронизации — нажмите, чтобы разобрать")
            default: return L("Синхронизировать все профили")
            }
        }())
        .sheet(isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })) {
            if let conflict { ConflictSheet(profileID: conflict.0, conflicts: conflict.1).environment(model) }
        }
    }
}
