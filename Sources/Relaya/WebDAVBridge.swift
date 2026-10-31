import AppKit
import Network
import NetFS
import RelayaCore

/// «SFTP как диск в Finder»: локальный WebDAV-сервер на 127.0.0.1 со случайным портом и секретным токеном в пути,
/// который превращает запросы Finder в операции SFTP/ssh. macOS подключает его сам (NetFS) — без расширений ядра,
/// без FUSE и без аккаунта разработчика. Диск называется как хост и появляется в боковой панели Finder.
@MainActor
final class WebDAVBridge {
    let host: SSHHost
    private let sftp: SFTPClient
    private let ssh: SSHInvocation
    private let token = UUID().uuidString.lowercased()
    private var listener: NWListener?
    private var root = "/"
    private(set) var mountPoint: URL?
    /// Служебные файлы Finder (`._*`, `.DS_Store`) живут только в памяти моста.
    private var junk: [String: Data] = [:]
    private var listings: [String: (files: [RemoteFile], at: Date)] = [:]

    var onStopped: (() -> Void)?

    init(host: SSHHost, sftp: SFTPClient, ssh: SSHInvocation) {
        self.host = host
        self.sftp = sftp
        self.ssh = ssh
    }

    private var volumeName: String {
        host.alias.replacingOccurrences(of: "/", with: "-")
    }
    private var prefix: String { "/\(token)/\(volumeName)" }

    /// Поднять сервер, подключить диск и открыть его в Finder.
    func start() async throws {
        root = try await sftp.home()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
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
            listener.start(queue: .main)
        }
        self.listener = listener
        guard let url = URL(string: "http://127.0.0.1:\(port)\(prefix)") else { return }
        mountPoint = try await Self.mount(url)
        if let mountPoint { NSWorkspace.shared.open(mountPoint) }
    }

    func stop() {
        if let mountPoint { FileManager.default.unmountVolume(at: mountPoint, options: []) { _ in } }
        mountPoint = nil
        listener?.cancel()
        listener = nil
        onStopped?()
    }

    private static func mount(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let open = NSMutableDictionary()
                open[kNAUIOptionKey] = kNAUIOptionNoUI
                open[kNetFSUseGuestKey] = true
                var points: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, open, nil, &points)
                if status == 0, let list = points?.takeRetainedValue() as? [String], let first = list.first {
                    cont.resume(returning: URL(fileURLWithPath: first))
                } else {
                    cont.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(status),
                                                  userInfo: [NSLocalizedDescriptionKey: L("Не удалось подключить диск (код %@).", "\(status)")]))
                }
            }
        }
    }

    // MARK: - Соединения

    private func accept(_ conn: NWConnection) {
        let c = DAVConnection(conn) { [weak self] req in
            await self?.handle(req) ?? WebDAV.response(503, "Service Unavailable")
        }
        connections.insert(c)
        c.onClose = { [weak self, weak c] in if let c { self?.connections.remove(c) } }
        c.start()
    }

    private var connections: Set<DAVConnection> = []

    // MARK: - Запросы

    private func remotePath(_ path: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        var rest = String(path.dropFirst(prefix.count))
        while rest.hasSuffix("/") && rest.count > 1 { rest.removeLast() }
        if rest.isEmpty || rest == "/" { return root }
        return SFTPClient.join(root, String(rest.drop(while: { $0 == "/" })))
    }

    private func handle(_ req: WebDAV.Request) async -> Data {
        guard !req.path.contains("/../"), !req.path.hasSuffix("/.."),
              let remote = remotePath(req.path) else { return WebDAV.response(404, "Not Found") }
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
                return WebDAV.response(200, "OK", headers: ["Content-Type": "application/xml; charset=utf-8",
                                                            "Lock-Token": "<opaquelocktoken:\(UUID().uuidString)>"],
                                       body: WebDAV.lockResponse(token: "opaquelocktoken:\(UUID().uuidString)", path: req.path))
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

/// Одно соединение Finder: запросы по очереди, ответы в том же порядке.
@MainActor
private final class DAVConnection: Hashable {
    private let conn: NWConnection
    private let handler: (WebDAV.Request) async -> Data
    private var parser = WebDAV.Parser()
    private var queue: [WebDAV.Request] = []
    private var busy = false
    var onClose: (() -> Void)?

    init(_ conn: NWConnection, handler: @escaping (WebDAV.Request) async -> Data) {
        self.conn = conn
        self.handler = handler
    }

    nonisolated static func == (a: DAVConnection, b: DAVConnection) -> Bool { a === b }
    nonisolated func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    func start() {
        conn.start(queue: .main)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.queue += self.parser.feed(data)
                    self.pump()
                }
                if done || error != nil {
                    self.conn.cancel()
                    self.onClose?()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let req = queue.removeFirst()
        Task { @MainActor in
            let data = await handler(req)
            conn.send(content: data, completion: .contentProcessed { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.busy = false
                    self?.pump()
                }
            })
        }
    }
}
