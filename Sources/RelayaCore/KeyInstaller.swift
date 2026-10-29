import Foundation

/// Генерация ключа, установка на сервер и проверка входа.
///
/// Пароль сервера и passphrase передаются ssh только через askpass-помощник:
/// сам Relaya, запущенный с `RELAYA_ASKPASS_ACCOUNT`, читает секрет из Keychain.
/// В аргументы и окружение секреты не попадают.
public struct KeyInstaller: Sendable {
    public var askpassExecutable: String
    public var keychain: KeychainStore

    public init(askpassExecutable: String, keychain: KeychainStore = KeychainStore()) {
        self.askpassExecutable = askpassExecutable
        self.keychain = keychain
    }

    /// Временное хранилище для секретов, которые пользователь не просил сохранять.
    public static let temporaryKeychain = KeychainStore(service: "app.relaya.temporary")

    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    public enum SecretKind: String, Sendable { case password, passphrase }

    /// Ссылка на секрет в Keychain для askpass.
    public struct SecretRef: Sendable {
        public var store: KeychainStore
        public var account: String
        public var kind: SecretKind

        public init(store: KeychainStore, account: String, kind: SecretKind) {
            self.store = store
            self.account = account
            self.kind = kind
        }
    }

    public func askpassEnvironment(_ secret: SecretRef) -> [String: String] {
        [
            "SSH_ASKPASS": askpassExecutable,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":0",
            "RELAYA_ASKPASS_ACCOUNT": secret.account,
            "RELAYA_ASKPASS_SERVICE": secret.store.service,
            "RELAYA_ASKPASS_KIND": secret.kind.rawValue,
        ]
    }

    // MARK: - Шаги

    public func generate(path: String, comment: String, passphrase: String) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path), !fm.fileExists(atPath: path + ".pub") else {
            throw Failure("Файл \(SSHPaths.abbreviate(path)) уже существует")
        }
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // -N виден в списке процессов долю секунды; ssh-keygen не умеет брать passphrase из askpass.
        let r = try await ProcessRunner.run("/usr/bin/ssh-keygen",
                                            ["-t", "ed25519", "-f", path, "-C", comment, "-N", passphrase, "-q"])
        guard r.succeeded else { throw Failure("ssh-keygen: \(r.message)") }
    }

    /// Дописывает ключ в `~/.ssh/authorized_keys` на сервере, если его там ещё нет.
    public func install(publicKey: String, alias: String, password: SecretRef?) async throws {
        let remote = Self.installScript
        var args = ["-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", "-o", "NumberOfPasswordPrompts=1"]
        var env: [String: String] = [:]
        if let password {
            env = askpassEnvironment(password)
            args += Self.passwordOnlyOptions
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        let r = try await ProcessRunner.run("/usr/bin/ssh", args + [alias, remote],
                                            environment: env, input: publicKey + "\n")
        guard r.succeeded else { throw Failure(Self.explain(r)) }
    }

    /// Удалённый скрипт установки ключа (POSIX sh, работает и в busybox).
    /// Ключ читается из stdin. Дописывается в `~/.ssh/authorized_keys`, а для root на системах
    /// с Dropbear (OpenWrt и др.) — ещё и в `/etc/dropbear/authorized_keys`: Dropbear читает ключи root оттуда.
    static let installScript = #"sh -c 'umask 077; read -r k || exit 1; add() { mkdir -p "${1%/*}" && touch "$1" && chmod 600 "$1" && { grep -qxF "$k" "$1" 2>/dev/null || printf "%s\n" "$k" >> "$1"; }; }; add "$HOME/.ssh/authorized_keys" && chmod 700 "$HOME/.ssh" || exit 1; if [ "$(id -u)" = 0 ] && [ -d /etc/dropbear ]; then add /etc/dropbear/authorized_keys || exit 1; fi'"#

    /// Определяет ОС сервера отдельным неинтерактивным входом (ключ, агент или пароль из Keychain).
    public func detectOS(alias: String, password: SecretRef?) async -> ServerOS? {
        var args = ["-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "NumberOfPasswordPrompts=1"]
        var env: [String: String] = [:]
        if let password {
            env = askpassEnvironment(password)
            args += Self.passwordOnlyOptions
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        guard let r = try? await ProcessRunner.run("/usr/bin/ssh", args + [alias, ServerOS.probeCommand], environment: env)
        else { return nil }
        return ServerOS.parse(probe: r.stdout + "\n" + r.stderr)
    }

    /// Загружает ключ в ssh-agent и сохраняет passphrase в системный Keychain (`--apple-use-keychain`).
    public func addToAgent(keyPath: String, passphrase: SecretRef?) async throws {
        let env = passphrase.map(askpassEnvironment) ?? [:]
        let r = try await ProcessRunner.run("/usr/bin/ssh-add", ["--apple-use-keychain", keyPath], environment: env)
        guard r.succeeded else { throw Failure("ssh-add: \(r.message)") }
    }

    /// Вход только этим ключом, без пароля.
    public func verify(alias: String, keyPath: String) async throws {
        let r = try await ProcessRunner.run("/usr/bin/ssh", [
            "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=no",
            "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15",
            "-i", keyPath, alias, "true",
        ])
        guard r.succeeded else {
            var msg = "Проверочный вход по ключу не прошёл: \(Self.explain(r))"
            if r.message.contains("Permission denied") {
                msg += ". Ключ на сервер добавлен, но сервер его не принимает — проверьте права (~/.ssh 700, authorized_keys 600, домашний каталог без записи для группы) и не отключён ли вход по ключу в настройках sshd."
            }
            throw Failure(msg)
        }
    }

    /// Сразу пароль, без перебора ключей: иначе ssh пробует все ключи из агента,
    /// и сервер рвёт соединение («Too many authentication failures») раньше, чем спросит пароль.
    public static let passwordOnlyOptions = [
        "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no",
    ]

    static func explain(_ r: ProcessResult) -> String {
        let m = r.message
        if m.contains("Connection refused") {
            return "сервер отклонил подключение к SSH (Connection refused). Обычно это значит, что sshd не запущен или ваш IP временно заблокирован после неудачных входов (fail2ban) — подождите 10–60 минут или проверьте сервер через консоль хостинга"
        }
        if m.contains("Operation timed out") || m.contains("Connection timed out") {
            return "сервер не отвечает (таймаут) — проверьте адрес, порт и файрвол"
        }
        if m.contains("Too many authentication failures") {
            return "сервер оборвал вход после перебора ключей из ssh-agent (Too many authentication failures). Введите пароль сервера на первом шаге — тогда вход пойдёт сразу по паролю"
        }
        if m.contains("Host key verification failed") {
            return "сервер ещё не в known_hosts — подключитесь к нему в терминале и подтвердите отпечаток"
        }
        if m.contains("Permission denied") { return "доступ запрещён (неверный пароль или ключ): \(m)" }
        return m.isEmpty ? "ssh завершился с кодом \(r.status)" : m
    }
}
