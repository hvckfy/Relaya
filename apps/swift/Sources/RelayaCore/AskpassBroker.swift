import Foundation
import Darwin
import LocalAuthentication

/// Выдача секретов askpass-помощнику без утечки другим процессам (M8).
///
/// Процесс Relaya, который запускает ssh/sftp (приложение или `Relaya --mcp`), поднимает свой UNIX-сокет (0600 в папке
/// 0700) и на каждый запуск выдаёт одноразовый токен: какая запись Keychain, пароль или passphrase, срок 2 минуты,
/// не больше 3 использований (ssh может переспросить). В окружение ssh попадают только путь сокета и токен.
/// Askpass-процесс сам Keychain не читает: предъявляет токен и текст запроса, а брокер проверяет, что звонящий —
/// потомок этого же процесса Relaya (askpass ← ssh [← sftp] ← мы), и только тогда отдаёт секрет.
/// По настройке «Touch ID при каждом использовании пароля» перед выдачей спрашивается Touch ID / пароль Mac.
public final class AskpassBroker: @unchecked Sendable {
    public static let shared = AskpassBroker()

    /// Настройка: подтверждать каждую выдачу секрета ssh (по умолчанию выключено).
    public static let confirmEachUseKey = "askpassConfirmEachUse"
    public static var confirmEachUse: Bool { UserDefaults.standard.bool(forKey: confirmEachUseKey) }

    private struct Grant {
        let secret: KeyInstaller.SecretRef
        var uses: Int
        let expires: Date
    }

    private let lock = NSLock()
    private var grants: [String: Grant] = [:]
    private var path: String?

    /// Токен на один запуск ssh. Ошибка — если сокет не поднялся (тогда пароль просто не подставится).
    public func issue(_ secret: KeyInstaller.SecretRef) throws -> (socket: String, token: String) {
        let socket = try startIfNeeded()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeyInstaller.Failure("askpass: random")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            grants = grants.filter { $0.value.expires > Date() }
            grants[token] = Grant(secret: secret, uses: 3, expires: Date().addingTimeInterval(120))
        }
        return (socket, token)
    }

    // MARK: - Сокет

    private func startIfNeeded() throws -> String {
        if let p = lock.withLock({ path }) { return p }
        let dir = FileManager.default.temporaryDirectory.appending(path: "relaya-askpass")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let file = dir.appending(path: "\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock").path
        unlink(file)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw KeyInstaller.Failure("askpass: socket") }
        var addr = Self.address(file)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(file, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw KeyInstaller.Failure("askpass: bind \(file)")
        }
        lock.withLock { path = file }
        let thread = Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue } else { break } }
                Thread.detachNewThread { self?.serve(client) }
            }
        }
        thread.name = "Relaya askpass"
        thread.start()
        atexit_b { unlink(file) }
        return file
    }

    static func address(_ file: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(file.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        return addr
    }

    /// Запрос: `токен\n` + текст приглашения ssh. Ответ: секрет или пусто (отказ).
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while request.count < 65536 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            request.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: request, as: UTF8.self)
        guard let nl = text.firstIndex(of: "\n") else { return }
        let token = String(text[..<nl])
        let prompt = String(text[text.index(after: nl)...])

        var peer: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &len) == 0, Self.descendsFromUs(peer) else { return }

        let grant: Grant? = lock.withLock {
            guard var g = grants[token], g.expires > Date(), g.uses > 0 else { return nil }
            g.uses -= 1
            grants[token] = g
            return g
        }
        guard let grant else { return }
        let expected = grant.secret.kind == .passphrase
            ? prompt.lowercased().contains("passphrase")
            : PasswordPrompt.matches(prompt)
        guard expected else { return }
        if Self.confirmEachUse, !Self.confirm(grant.secret) { return }
        guard let secret = try? grant.secret.store.password(for: grant.secret.account) else { return }
        _ = Array(secret.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// askpass ← ssh [← sftp/ssh] ← этот процесс: не дальше 4 шагов вверх.
    static func descendsFromUs(_ pid: pid_t) -> Bool {
        let me = getpid()
        var current = pid
        for _ in 0..<4 {
            guard let parent = parent(of: current), parent > 1 else { return false }
            if parent == me { return true }
            current = parent
        }
        return false
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Touch ID / пароль Mac перед выдачей (настройка). Поток askpass ждёт ответа.
    private static func confirm(_ secret: KeyInstaller.SecretRef) -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let done = DispatchSemaphore(value: 0)
        let ok = LockedFlag()
        let what = secret.kind == .passphrase ? L("passphrase ключа") : L("пароль")
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: L("ssh просит %@ для %@", what, secret.account)) { success, _ in
            ok.value = success
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        return ok.value
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    // MARK: - Клиент (askpass-режим)

    /// Askpass-процесс: отправить токен и приглашение, получить секрет. nil — отказ.
    public static func request(socket file: String, token: String, prompt: String) -> String? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = address(file)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let message = Array((token + "\n" + prompt).utf8)
        guard message.withUnsafeBufferPointer({ write(fd, $0.baseAddress, $0.count) }) == message.count else { return nil }
        shutdown(fd, SHUT_WR)
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        let secret = String(decoding: reply, as: UTF8.self)
        return secret.isEmpty ? nil : secret
    }
}
