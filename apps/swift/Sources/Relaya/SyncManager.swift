import AppKit
import Observation
import RelayaCore

/// Личная синхронизация по профилям: у каждого — свой git-репозиторий (или папка iCloud Drive) и свой набор хостов.
/// Профили — в UserDefaults, пароль шифрования ключей — в Keychain. Состояние — в тулбаре и в настройках.
@MainActor
@Observable
final class SyncManager {
    enum State: Equatable {
        case idle, syncing
        case conflict([GitSync.Conflict])
        case failed(String)
    }

    var profiles: [Sync.Profile] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: "syncProfiles")
            scheduleAuto()
        }
    }
    private(set) var states: [Sync.Profile.ID: State] = [:]
    private(set) var lastSync: [String: Date] = (UserDefaults.standard.dictionary(forKey: "syncLastByProfile") as? [String: Date]) ?? [:] {
        didSet { UserDefaults.standard.set(lastSync, forKey: "syncLastByProfile") }
    }

    /// После того как пришли файлы — модель перечитывает хосты, сниппеты и прочее.
    @ObservationIgnored var onImported: (([Sync.Item]) -> Void)?
    @ObservationIgnored private var timer: Timer?
    private let keychain = KeychainStore()
    private static let passphraseAccount = "relaya-sync-keys"

    init() {
        profiles = UserDefaults.standard.data(forKey: "syncProfiles")
            .flatMap { try? JSONDecoder().decode([Sync.Profile].self, from: $0) } ?? []
    }

    var activeProfiles: [Sync.Profile] { RelayaPaths.isDemo ? [] : profiles.filter(\.enabled) }

    func state(_ p: Sync.Profile) -> State { states[p.id] ?? .idle }

    /// Сводное состояние для тулбара: конфликт важнее ошибки, ошибка важнее синхронизации.
    var overall: State {
        let all = activeProfiles.map(state)
        if let c = all.first(where: { if case .conflict = $0 { true } else { false } }) { return c }
        if let f = all.first(where: { if case .failed = $0 { true } else { false } }) { return f }
        return all.contains(.syncing) ? .syncing : .idle
    }

    var hasPassphrase: Bool { keychain.hasPassword(for: Self.passphraseAccount) }

    func setPassphrase(_ value: String) {
        if value.isEmpty { try? keychain.deletePassword(for: Self.passphraseAccount) }
        else { try? keychain.setPassword(value, for: Self.passphraseAccount) }
    }

    func addProfile() -> Sync.Profile {
        let p = Sync.Profile(name: profiles.isEmpty ? L("Все хосты") : L("Профиль %@", "\(profiles.count + 1)"))
        profiles.append(p)
        return p
    }

    func remove(_ id: Sync.Profile.ID) {
        profiles.removeAll { $0.id == id }
        states[id] = nil
        try? FileManager.default.removeItem(at: repoDirectory(id))
    }

    private func repoDirectory(_ id: Sync.Profile.ID) -> URL {
        RelayaPaths.supportDirectory.appending(path: "sync").appending(path: id.uuidString)
    }

    private func git(_ p: Sync.Profile) -> GitSync {
        GitSync(repo: repoDirectory(p.id), remote: p.remote.trimmingCharacters(in: .whitespaces))
    }

    private var machine: String { Host.current().localizedName ?? "Mac" }

    /// Запуск: синхронизировать всё и включить таймер (каждые 10 минут).
    func start() {
        scheduleAuto()
        Task { await syncAll(interactive: false) }
    }

    private func scheduleAuto() {
        timer?.invalidate()
        timer = nil
        guard activeProfiles.contains(where: \.auto) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.syncAll(interactive: false) }
        }
    }

    func syncAll(interactive: Bool = true) async {
        for p in activeProfiles where interactive || p.auto {
            await sync(p.id, interactive: interactive)
        }
    }

    /// Пароль ключей — только если в профиле включены ключи; в фоне без Touch ID ключи пропускаются.
    private func keysPassphrase(_ p: Sync.Profile, interactive: Bool) async -> String? {
        guard p.effectiveItems.contains(.keys), hasPassphrase else { return nil }
        if !SecretGate.shared.isUnlocked {
            guard interactive, await SecretGate.shared.authorize(L("Синхронизировать SSH-ключи")) else { return nil }
        }
        return try? keychain.password(for: Self.passphraseAccount)
    }

    func sync(_ id: Sync.Profile.ID, interactive: Bool = true) async {
        guard let p = profiles.first(where: { $0.id == id }), p.enabled, state(p) != .syncing else { return }
        if case .conflict = state(p), !interactive { return }
        states[id] = .syncing
        let pass = await keysPassphrase(p, interactive: interactive)
        var imported: [Sync.Item] = []
        do {
            switch p.backend {
            case .iCloud:
                guard FolderSync.iCloudAvailable else { throw GitSync.Failure(message: L("iCloud Drive не включён на этом Mac.")) }
                // Трёхстороннее слияние (C8): свежие правки на любой машине не затираются; спор — экран конфликта.
                switch try await FolderSync.merge(p, passphrase: pass, folder: FolderSync.folder(for: p)) {
                case .conflict(let c):
                    states[id] = .conflict(c)
                    return
                case .synced(_, let items):
                    imported = items
                case .upToDate:
                    break
                }
            case .git:
                guard !p.remote.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw GitSync.Failure(message: L("Укажите репозиторий."))
                }
                let outcome = try await git(p).sync(machine: machine, profile: p, passphrase: pass)
                switch outcome {
                case .conflict(let c):
                    states[id] = .conflict(c)
                    return
                case .synced(_, let items):
                    imported = items
                case .upToDate:
                    break
                }
            }
            finish(id, imported)
        } catch {
            states[id] = .failed(error.localizedDescription)
        }
    }

    /// Пользователь выбрал версии файлов с конфликтом: `true` — моя.
    func resolve(_ id: Sync.Profile.ID, _ choices: [String: Bool]) async {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        let git = self.git(p)
        let pass = await keysPassphrase(p, interactive: true)
        states[id] = .syncing
        var imported: [Sync.Item] = []
        do {
            if p.backend == .iCloud {
                if case .synced(_, let items) = try await FolderSync.merge(p, passphrase: pass, folder: FolderSync.folder(for: p),
                                                                            keepMine: choices) { imported = items }
            } else {
                imported = try await git.resolve(choices, profile: p, passphrase: pass)
            }
            finish(id, imported)
        } catch {
            states[id] = .failed(error.localizedDescription)
        }
    }

    /// Отложить конфликт: слияние отменяется, ничего не меняется ни здесь, ни на сервере.
    func postpone(_ id: Sync.Profile.ID) async {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        if p.backend == .git { try? await git(p).abortMerge() }
        states[id] = .failed(L("Есть конфликт — синхронизация отложена."))
    }

    func lastSync(_ p: Sync.Profile) -> Date? { lastSync[p.id.uuidString] }

    /// Ключи с другой машины, не совпавшие с местными одноимёнными (сохранены рядом как `.from-sync`).
    var renamedKeys: [(name: String, savedAs: String)] = []
    /// Пришедшие ключи не загружены (нет или неверный пароль шифрования) — показывается в настройках синхронизации.
    var skippedKeysNotice: String?

    private func finish(_ id: Sync.Profile.ID, _ imported: [Sync.Item]) {
        lastSync[id.uuidString] = Date()
        states[id] = .idle
        renamedKeys += Sync.takeRenamedKeys()
        let skipped = Sync.takeSkippedKeys()
        skippedKeysNotice = skipped.wrongPassphrase.isEmpty && skipped.noPassphrase.isEmpty ? nil
            : !skipped.wrongPassphrase.isEmpty
                ? L("Ключи не загружены — пароль шифрования ключей не подошёл: %@", skipped.wrongPassphrase.joined(separator: ", "))
                : L("Ключи не загружены — задайте пароль шифрования ключей (тот же, что на другой машине): %@",
                    skipped.noPassphrase.joined(separator: ", "))
        if !imported.isEmpty { onImported?(imported) }
    }
}
