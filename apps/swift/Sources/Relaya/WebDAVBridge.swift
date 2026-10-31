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

    /// Папка на сервере, которая стала диском.
    let remoteRoot: String

    /// `remoteRoot` — папка на сервере (`/` — весь сервер, `~` — домашняя).
    init(host: SSHHost, remoteRoot: String, sftp: SFTPClient, ssh: SSHInvocation) {
        self.host = host
        self.remoteRoot = remoteRoot
        server = DAVServer(volumeName: Self.volumeName(alias: host.alias, path: remoteRoot), root: remoteRoot, sftp: sftp, ssh: ssh)
    }

    /// Имя диска в Finder: хост, а для вложенной папки — «хост · папка».
    static func volumeName(alias: String, path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let name = path == "/" || path.isEmpty || last.isEmpty || last == "/" ? alias
            : path == "~" ? "\(alias) · ~" : "\(alias) · \(last)"
        return name.replacingOccurrences(of: "/", with: "-")
    }

    /// Поднять сервер, подключить диск и открыть его в Finder.
    func start() async throws {
        try await server.prepare()
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
        let mp = try await Self.mount(url, password: server.password)
        mountPoint = mp
        // Открыть в Finder — не из главного потока: обращение к диску идёт к нашему же серверу.
        if let mp { DispatchQueue.global().async { NSWorkspace.shared.open(mp) } }
    }

    func stop() {
        if let mountPoint { FileManager.default.unmountVolume(at: mountPoint, options: []) { _ in } }
        mountPoint = nil
        listener?.cancel()
        listener = nil
        onStopped?()
    }

    /// Открыть уже подключённый диск в Finder.
    func reveal() {
        guard let mp = mountPoint else { return }
        DispatchQueue.global().async { NSWorkspace.shared.open(mp) }
    }

    private static func mount(_ url: URL, password: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let open = NSMutableDictionary()
                open[kNAUIOptionKey] = kNAUIOptionNoUI
                // Не гостем: сервер требует Basic-аутентификацию со случайным паролем этого подключения,
                // иначе к диску мог бы обратиться любой локальный процесс, узнавший порт и путь.
                var points: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(url as CFURL, nil, DAVServer.user as CFString, password as CFString,
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

/// Обработка запросов WebDAV: состояние моста (кэш списков, служебные файлы Finder) — внутри актора.
actor DAVServer {
    nonisolated let prefix: String
    /// Basic-аутентификация моста: пароль случайный на каждое подключение диска.
    nonisolated static let user = "relaya"
    nonisolated let password = UUID().uuidString + UUID().uuidString
    private let volumeName: String
    private let sftp: SFTPClient
    private let ssh: SSHInvocation
    private var root = "/"
    /// Служебные файлы Finder (`._*`, `.DS_Store`) живут только в памяти моста.
    private var junk: [String: Data] = [:]
    private var listings: [String: (files: [RemoteFile], at: Date)] = [:]

    private let requestedRoot: String

    init(volumeName: String, root: String, sftp: SFTPClient, ssh: SSHInvocation) {
        self.volumeName = volumeName
        requestedRoot = root
        self.sftp = sftp
        self.ssh = ssh
        prefix = "/\(UUID().uuidString.lowercased())/\(volumeName)"
    }

    /// Проверить папку: `~` и пустое — домашняя, `~/x` — внутри домашней; несуществующая — ошибка.
    func prepare() async throws {
        let r = requestedRoot.trimmingCharacters(in: .whitespaces)
        if r.isEmpty || r == "~" {
            root = try await sftp.home()
        } else if r.hasPrefix("~/") {
            root = SFTPClient.join(try await sftp.home(), String(r.dropFirst(2)))
        } else {
            root = r.hasPrefix("/") ? r : "/" + r
        }
        _ = try await sftp.list(root)
    }

    // MARK: - Запросы

    /// Путь запроса → путь на сервере. Только внутри префикса (с границей `/`) и без `.`/`..` в компонентах,
    /// чтобы ни запрос, ни Destination у MOVE/COPY не вышли за корень диска.
    func remotePath(_ path: String) -> String? {
        guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.isEmpty ? root : SFTPClient.join(root, parts.joined(separator: "/"))
    }

    private var expectedAuthorization: String {
        "Basic " + Data("\(Self.user):\(password)".utf8).base64EncodedString()
    }

    func handle(_ req: WebDAV.Request) async -> Data {
        guard req.header("authorization") == expectedAuthorization else {
            return WebDAV.response(401, "Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Relaya\""])
        }
        guard let remote = remotePath(req.path) else { return WebDAV.response(404, "Not Found") }
        if remote == root, ["DELETE", "MOVE"].contains(req.method) { return WebDAV.response(403, "Forbidden") }
        let name = (remote as NSString).lastPathComponent
        do {
            switch req.method {
            case "OPTIONS":
                return WebDAV.response(200, "OK", headers: ["Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK"])
            case "PROPFIND":
                return try await propfind(req, remote: remote)
            case "PROPPATCH":
                return WebDAV.response(207, "Multi-Status", headers: ["Content-Type": "application/xml; charset=utf-8"],
                                       body: WebDAV.multistatus([]))
            case "LOCK":
                let token = "opaquelocktoken:\(UUID().uuidString)"
                return WebDAV.response(200, "OK", headers: ["Content-Type": "application/xml; charset=utf-8",
                                                            "Lock-Token": "<\(token)>"],
                                       body: WebDAV.lockResponse(token: token, path: req.path))
            case "UNLOCK":
                return WebDAV.response(204, "No Content")
            case "GET", "HEAD":
                if WebDAV.isFinderJunk(name) {
                    guard let d = junk[remote] else { return WebDAV.response(404, "Not Found") }
                    return WebDAV.response(200, "OK", body: req.method == "HEAD" ? Data() : d)
                }
                if req.method == "HEAD" {
                    guard let f = try await stat(remote) else { return WebDAV.response(404, "Not Found") }
                    return WebDAV.response(200, "OK", headers: ["Content-Length": "\(f.size)"])
                }
                let tmp = FileManager.default.temporaryDirectory.appending(path: "relaya-dav-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await StreamTransfer.download(ssh, remotePath: remote, to: tmp) { _ in }
                return WebDAV.response(200, "OK", headers: ["Content-Type": "application/octet-stream"],
                                       body: try Data(contentsOf: tmp))
            case "PUT":
                if WebDAV.isFinderJunk(name) { junk[remote] = req.body; return WebDAV.response(201, "Created") }
                let tmp = FileManager.default.temporaryDirectory.appending(path: "relaya-dav-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try req.body.write(to: tmp)
                try await StreamTransfer.upload(ssh, localURL: tmp, remoteDirectory: SFTPClient.parent(of: remote),
                                                name: name) { _ in }
                invalidate(remote)
                return WebDAV.response(201, "Created")
            case "MKCOL":
                try await sftp.makeDirectory(remote)
                invalidate(remote)
                return WebDAV.response(201, "Created")
            case "DELETE":
                if WebDAV.isFinderJunk(name) { junk[remote] = nil; return WebDAV.response(204, "No Content") }
                // Finder сам спрашивает «Удалить сразу?» — папки удаляются целиком, как на любом сетевом диске.
                try await shell("rm -rf -- \(StreamTransfer.quote(remote))")
                invalidate(remote)
                return WebDAV.response(204, "No Content")
            case "MOVE", "COPY":
                guard let dest = WebDAV.destinationPath(req.header("destination")).flatMap(remotePath) else {
                    return WebDAV.response(400, "Bad Request")
                }
                if WebDAV.isFinderJunk(name) {
                    junk[dest] = junk[remote]
                    if req.method == "MOVE" { junk[remote] = nil }
                    return WebDAV.response(201, "Created")
                }
                let overwrite = req.header("overwrite")?.uppercased() != "F"
                let tool = req.method == "MOVE" ? "mv" : "cp -a"
                try await shell("\(tool) \(overwrite ? "" : "-n ")-- \(StreamTransfer.quote(remote)) \(StreamTransfer.quote(dest))")
                invalidate(remote)
                invalidate(dest)
                return WebDAV.response(201, "Created")
            default:
                return WebDAV.response(405, "Method Not Allowed")
            }
        } catch {
            return WebDAV.response(500, "Internal Server Error", body: Data(error.localizedDescription.utf8))
        }
    }

    private func propfind(_ req: WebDAV.Request, remote: String) async throws -> Data {
        let href = req.path
        let isRoot = remote == root
        let selfEntry: WebDAV.Entry
        if isRoot {
            selfEntry = .init(href: href, name: volumeName, isDirectory: true, size: 0, modified: Date())
        } else {
            let name = (remote as NSString).lastPathComponent
            if WebDAV.isFinderJunk(name) {
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

    private func shell(_ command: String) async throws {
        let r = try await ProcessRunner.run("/usr/bin/ssh", ssh.options + [ssh.alias, command],
                                            environment: ssh.environment, timeout: .seconds(120))
        guard r.succeeded else { throw StreamTransfer.Failure(message: r.message.isEmpty ? "ssh: \(r.status)" : r.message) }
    }
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
