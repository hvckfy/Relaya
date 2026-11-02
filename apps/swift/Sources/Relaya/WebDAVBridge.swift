import AppKit
import Network
import NetFS
import RelayaCore

/// «SFTP как диск в Finder»: локальный WebDAV-сервер на 127.0.0.1 со случайным портом и секретным токеном в пути,
/// который превращает запросы Finder в операции SFTP/ssh. macOS подключает его сам (NetFS) — без расширений ядра,
/// без FUSE и без аккаунта разработчика. Диск называется как хост и появляется в боковой панели Finder.
///
/// Сервер работает в своей очереди и своём акторе, а не в главном потоке: Relaya сама обращается к этому диску
/// (Finder, проверка существования), и если бы сервер ждал главный поток — получилась бы взаимная блокировка.
@MainActor
final class WebDAVBridge {
    let host: SSHHost
    private let server: DAVServer
    private var listener: NWListener?
    private(set) var mountPoint: URL?
    private let queue = DispatchQueue(label: "app.relaya.webdav")
    var onStopped: (() -> Void)?
    /// The server refused the login while the disk was in use; the disk is unmounted right after (B-5).
    var onRefused: ((String) -> Void)?

    /// Папка на сервере, которая стала диском.
    let remoteRoot: String

    /// `remoteRoot` — папка на сервере (`/` — весь сервер, `~` — домашняя).
    init(host: SSHHost, remoteRoot: String, sftp: SFTPClient, ssh: SSHInvocation) {
        self.host = host
        self.remoteRoot = remoteRoot
        server = DAVServer(volumeName: WebDAV.volumeName(alias: host.alias, path: remoteRoot), root: remoteRoot, sftp: sftp, ssh: ssh)
    }

    /// Поднять сервер, подключить диск и открыть его в Finder.
    func start() async throws {
        try await server.prepare()
        let owner = WeakBridge(self)
        await server.setOnRefused { reason in
            DispatchQueue.main.async {
                guard let bridge = owner.bridge else { return }
                bridge.onRefused?(reason)
                bridge.stop()
            }
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let server = self.server
        let queue = self.queue
        listener.newConnectionHandler = { conn in
            DAVConnection(conn, queue: queue) { await server.handle($0) }.start()
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e):
                    if once.fire() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        guard let url = URL(string: "http://127.0.0.1:\(port)\(server.prefix)") else { return }
        let mp = try await Self.mount(url, user: server.user, password: server.password)
        mountPoint = mp
        // Открыть в Finder — не из главного потока: обращение к диску идёт к нашему же серверу.
        if let mp { DispatchQueue.global().async { NSWorkspace.shared.open(mp) } }
    }

    /// Отключить диск и остановить сервер. Отключение — не из главного потока: система перед ним обращается к диску,
    /// то есть к этому же серверу, и ожидание в главном потоке подвешивало Relaya. Сервер работает, пока диск не отключён.
    /// `wait` — сколько ждать отключения (выход из приложения); 0 — не ждать.
    func stop(wait: Duration = .zero) {
        let mp = mountPoint
        let listener = self.listener
        mountPoint = nil
        self.listener = nil
        onStopped?()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if let mp { Self.unmount(mp) }
            listener?.cancel()
            done.signal()
        }
        if wait > .zero {
            let (sec, atto) = wait.components
            _ = done.wait(timeout: .now() + .nanoseconds(Int(sec) * 1_000_000_000 + Int(atto / 1_000_000_000)))
        }
    }

    /// unmount(2), а не FileManager: тот сначала читает атрибуты тома. Занят (открытый файл) — принудительно,
    /// иначе диск остался бы подключённым к уже остановленному серверу.
    nonisolated private static func unmount(_ mp: URL) {
        guard Darwin.unmount(mp.path, 0) != 0 else { return }
        if Darwin.unmount(mp.path, MNT_FORCE) != 0 {
            NSLog("Relaya WebDAV: диск %@ не отключён: %@", mp.path, String(cString: strerror(errno)))
        }
    }

    /// Открыть уже подключённый диск в Finder.
    func reveal() {
        guard let mp = mountPoint else { return }
        DispatchQueue.global().async { NSWorkspace.shared.open(mp) }
    }

    private static func mount(_ url: URL, user: String, password: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let open = NSMutableDictionary()
                open[kNAUIOptionKey] = kNAUIOptionNoUI
                // Не гостем: сервер требует Basic-аутентификацию со случайным паролем этого подключения,
                // иначе к диску мог бы обратиться любой локальный процесс, узнавший порт и путь.
                var points: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(url as CFURL, nil, user as CFString, password as CFString,
                                               open, nil, &points)
                if status == 0, let list = points?.takeRetainedValue() as? [String], let first = list.first {
                    cont.resume(returning: URL(fileURLWithPath: first))
                } else {
                    cont.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(status),
                                                  userInfo: [NSLocalizedDescriptionKey: L("Не удалось подключить диск (код %@).", "\(status)")]))
                }
            }
        }
    }
}

/// Обработка запросов WebDAV: решение по запросу — в ядре (`WebDAV.decide`), здесь — только sftp/ssh и состояние
/// моста (кэш списков, служебные файлы Finder) внутри актора.
actor DAVServer {
    /// Путь `/<uuid>/<имя диска>` и Basic-пароль — случайные на каждое подключение.
    nonisolated let prefix: String
    nonisolated let user: String
    nonisolated let password: String
    private let volumeName: String
    private let sftp: SFTPClient
    private let ssh: SSHInvocation
    private var root = "/"
    /// Служебные файлы Finder (`._*`, `.DS_Store`) живут только в памяти моста.
    private var junk: [String: Data] = [:]
    private var listings: [String: (files: [RemoteFile], at: Date)] = [:]
    /// B-5: the server refused the login after the disk was mounted (password changed, key revoked, account
    /// locked). From then on no ssh is started: Finder keeps retrying, and each retry would be another failed login.
    private var refused: String?
    private var onRefused: (@Sendable (String) -> Void)?

    func setOnRefused(_ handler: @escaping @Sendable (String) -> Void) { onRefused = handler }

    private let requestedRoot: String

    init(volumeName: String, root: String, sftp: SFTPClient, ssh: SSHInvocation) {
        self.volumeName = volumeName
        requestedRoot = root
        self.sftp = sftp
        self.ssh = ssh
        let secrets = WebDAV.newSecrets(volumeName: volumeName)
        prefix = secrets.prefix
        user = secrets.user
        password = secrets.password
    }

    /// Проверить папку: корень разрешает ядро (`~`, `~/x`, абсолютный; `..` — ошибка), несуществующая — ошибка.
    func prepare() async throws {
        let home = WebDAV.rootNeedsHome(requestedRoot) ? try await sftp.home() : ""
        root = try WebDAV.resolveRoot(requestedRoot, home: home)
        _ = try await sftp.list(root)
    }

    // MARK: - Запросы

    func handle(_ req: WebDAV.Request) async -> Data {
        guard WebDAV.isAuthorized(req.header("authorization"), password: password) else {
            return WebDAV.response(401, "Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Relaya\""])
        }
        if refused != nil { return WebDAV.response(503, "Service Unavailable") }
        do {
            switch WebDAV.decide(req, prefix: prefix, root: root) {
            case let .reply(status, reason):
                return WebDAV.response(Int(status), reason)
            case .options:
                return WebDAV.response(200, "OK", headers: ["Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK"])
            case let .propfind(remote, isJunk):
                return try await propfind(req, remote: remote, isJunk: isJunk)
            case .proppatch:
                return WebDAV.response(207, "Multi-Status", headers: ["Content-Type": "application/xml; charset=utf-8"],
                                       body: WebDAV.multistatus([]))
            case .lock:
                let token = "opaquelocktoken:\(UUID().uuidString)"
                return WebDAV.response(200, "OK", headers: ["Content-Type": "application/xml; charset=utf-8",
                                                            "Lock-Token": "<\(token)>"],
                                       body: WebDAV.lockResponse(token: token, path: req.path))
            case .unlock:
                return WebDAV.response(204, "No Content")
            case let .get(remote, isJunk), let .head(remote, isJunk):
                let isHead = req.method == "HEAD"
                if isJunk {
                    guard let d = junk[remote] else { return WebDAV.response(404, "Not Found") }
                    return WebDAV.response(200, "OK", body: isHead ? Data() : d)
                }
                if isHead {
                    guard let f = try await stat(remote) else { return WebDAV.response(404, "Not Found") }
                    return WebDAV.response(200, "OK", headers: ["Content-Length": "\(f.size)"])
                }
                let tmp = try WebDAV.tempFile()
                defer { removeTemp(tmp) }
                try await StreamTransfer.download(ssh, remotePath: remote, to: tmp) { _ in }
                return WebDAV.response(200, "OK", headers: ["Content-Type": "application/octet-stream"],
                                       body: try Data(contentsOf: tmp))
            case let .put(remote, isJunk):
                if isJunk { junk[remote] = req.body; return WebDAV.response(201, "Created") }
                let tmp = try WebDAV.tempFile()
                defer { removeTemp(tmp) }
                try req.body.write(to: tmp)
                try await StreamTransfer.upload(ssh, localURL: tmp, remoteDirectory: SFTPClient.parent(of: remote),
                                                name: (remote as NSString).lastPathComponent) { _ in }
                invalidate(remote)
                return WebDAV.response(201, "Created")
            case let .mkcol(remote):
                try await sftp.makeDirectory(remote)
                invalidate(remote)
                return WebDAV.response(201, "Created")
            case let .delete(remote, isJunk):
                if isJunk { junk[remote] = nil; return WebDAV.response(204, "No Content") }
                // Finder сам спрашивает «Удалить сразу?» — папки удаляются целиком, как на любом сетевом диске.
                try await shell(WebDAV.deleteCommand(remote))
                invalidate(remote)
                return WebDAV.response(204, "No Content")
            case let .transfer(source, destination, isMove, overwrite, isJunk):
                if isJunk {
                    junk[destination] = junk[source]
                    if isMove { junk[source] = nil }
                    return WebDAV.response(201, "Created")
                }
                let existed = try await exists(destination)
                switch WebDAV.transferPlan(source: source, destination: destination, isMove: isMove,
                                           overwrite: overwrite, destinationExists: existed) {
                case let .reply(status, reason):
                    return WebDAV.response(Int(status), reason)
                case let .run(command, status, reason):
                    try await shell(command)
                    invalidate(source)
                    invalidate(destination)
                    return WebDAV.response(Int(status), reason)
                }
            }
        } catch {
            let message = error.localizedDescription
            // Only a refused login stops the disk; "Permission denied" from a command (a read-only folder) does not.
            let refusedLogin = (error as? StreamTransfer.Failure)?.loginRefused == true
                || (error as? SFTPClient.Failure)?.loginRefused == true
            if refusedLogin {
                if refused == nil {
                    refused = message
                    onRefused?(message)
                }
                return WebDAV.response(503, "Service Unavailable")
            }
            return WebDAV.response(500, "Internal Server Error", body: Data(message.utf8))
        }
    }

    /// Временный файл удаляется сразу после запроса; не удалось — ошибка в журнал, ответ уже собран.
    private func removeTemp(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch let e as CocoaError where e.code == .fileNoSuchFile {
            // Файла уже нет (download не успел его создать) — удалять нечего.
        } catch { NSLog("Relaya WebDAV: временный файл не удалён: \(error.localizedDescription)") }
    }

    private func propfind(_ req: WebDAV.Request, remote: String, isJunk: Bool) async throws -> Data {
        let href = req.path
        let isRoot = remote == root
        let selfEntry: WebDAV.Entry
        if isRoot {
            selfEntry = .init(href: href, name: volumeName, isDirectory: true, size: 0, modified: Date())
        } else {
            let name = (remote as NSString).lastPathComponent
            if isJunk {
                guard let d = junk[remote] else { return WebDAV.response(404, "Not Found") }
                selfEntry = .init(href: href, name: name, isDirectory: false, size: Int64(d.count), modified: Date())
            } else {
                guard let f = try await stat(remote) else { return WebDAV.response(404, "Not Found") }
                selfEntry = entry(f, href: href)
            }
        }
        var entries = [selfEntry]
        if req.depth > 0, selfEntry.isDirectory {
            let base = href.hasSuffix("/") ? href : href + "/"
            for f in try await list(remote) where !WebDAV.isFinderJunk(f.name) {
                entries.append(entry(f, href: base + f.name + (f.isDirectory ? "/" : "")))
            }
        }
        return WebDAV.response(207, "Multi-Status", headers: ["Content-Type": "application/xml; charset=utf-8"],
                               body: WebDAV.multistatus(entries))
    }

    private func entry(_ f: RemoteFile, href: String) -> WebDAV.Entry {
        .init(href: href, name: f.name, isDirectory: f.isDirectory, size: f.size,
              modified: WebDAV.date(fromListing: f.modified))
    }

    private func list(_ dir: String) async throws -> [RemoteFile] {
        if let cached = listings[dir], Date().timeIntervalSince(cached.at) < 3 { return cached.files }
        let files = try await sftp.list(dir)
        listings[dir] = (files, Date())
        return files
    }

    private func stat(_ path: String) async throws -> RemoteFile? {
        let name = (path as NSString).lastPathComponent
        return try? await list(SFTPClient.parent(of: path)).first { $0.name == name }
    }

    private func invalidate(_ path: String) {
        listings[SFTPClient.parent(of: path)] = nil
        listings[path] = nil
    }

    /// Есть ли путь на сервере (файл, папка или ссылка).
    private func exists(_ path: String) async throws -> Bool {
        let r = try await ProcessRunner.run("/usr/bin/ssh", ssh.options + [ssh.alias, WebDAV.existsCommand(path)],
                                            environment: ssh.environment, timeout: .seconds(60))
        if r.status == 0 { return true }
        if r.status == 1 { return false }
        throw StreamTransfer.Failure(message: r.message.isEmpty ? "ssh: \(r.status)" : r.message,
                                     loginRefused: r.status == 255 && SSHErrorText.loginRefused(r.stderr))
    }

    private func shell(_ command: String) async throws {
        let r = try await ProcessRunner.run("/usr/bin/ssh", ssh.options + [ssh.alias, command],
                                            environment: ssh.environment, timeout: .seconds(120))
        guard r.succeeded else {
            throw StreamTransfer.Failure(message: r.message.isEmpty ? "ssh: \(r.status)" : r.message,
                                         loginRefused: r.status == 255 && SSHErrorText.loginRefused(r.stderr))
        }
    }
}

/// Weak reference the server's refusal callback can carry across threads; the bridge is used on the main thread.
private final class WeakBridge: @unchecked Sendable {
    weak var bridge: WebDAVBridge?
    init(_ bridge: WebDAVBridge) { self.bridge = bridge }
}

/// Срабатывает один раз — для continuation, который ждёт первого из нескольких событий.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Одно соединение Finder: запросы по очереди, ответы в том же порядке. Всё состояние — в своей очереди.
private final class DAVConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let handler: @Sendable (WebDAV.Request) async -> Data
    private var parser = WebDAV.Parser()
    private var pending: [WebDAV.Request] = []
    private var busy = false
    /// Соединение держит само себя, пока открыто.
    private var keepAlive: DAVConnection?

    init(_ conn: NWConnection, queue: DispatchQueue, handler: @escaping @Sendable (WebDAV.Request) async -> Data) {
        self.conn = conn
        self.queue = queue
        self.handler = handler
    }

    func start() {
        keepAlive = self
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            if let data, !data.isEmpty {
                pending += parser.feed(data)
                pump()
            }
            if done || error != nil {
                conn.cancel()
                keepAlive = nil
            } else {
                receive()
            }
        }
    }

    private func pump() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let req = pending.removeFirst()
        let handler = self.handler
        Task.detached { [self] in
            let data = await handler(req)
            queue.async { [self] in
                conn.send(content: data, completion: .contentProcessed { [self] _ in
                    busy = false
                    pump()
                })
            }
        }
    }
}
