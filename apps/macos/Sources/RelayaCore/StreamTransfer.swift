import Foundation

/// Как запускать ssh для хоста: аргументы (ключ/агент или пароль через askpass) и окружение.
public struct SSHInvocation: Sendable {
    public var alias: String
    public var options: [String]
    public var environment: [String: String]

    public init(alias: String, options: [String], environment: [String: String]) {
        self.alias = alias
        self.options = options
        self.environment = environment
    }

    func configure(_ process: Process, command: String) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = options + [alias, command]
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
    }
}

/// Передача одного файла потоком через ssh (`cat`), с точным счётчиком байт и отменой.
/// Папки передаются через `sftp -r` (SFTPClient) — без процентов.
public enum StreamTransfer {
    public struct Failure: Error, LocalizedError {
        public var message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Скачать `remotePath` в `localURL`. При ошибке или отмене частичный файл удаляется.
    public static func download(_ ssh: SSHInvocation, remotePath: String, to localURL: URL,
                                progress: @escaping @Sendable (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: localURL)
        let box = ProcessBox()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let process = Process()
                    ssh.configure(process, command: "cat -- " + quote(remotePath))
                    let stdout = Pipe(), stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    process.standardInput = FileHandle.nullDevice
                    let reader = stdout.fileHandleForReading
                    let errReader = stderr.fileHandleForReading
                    let counter = Counter()
                    reader.readabilityHandler = { h in
                        let data = h.availableData
                        guard !data.isEmpty else { h.readabilityHandler = nil; return }
                        try? out.write(contentsOf: data)
                        progress(counter.add(data.count))
                    }
                    process.terminationHandler = { p in
                        reader.readabilityHandler = nil
                        let rest = reader.readDataToEndOfFile()
                        if !rest.isEmpty {
                            try? out.write(contentsOf: rest)
                            progress(counter.add(rest.count))
                        }
                        try? out.close()
                        let err = String(decoding: errReader.readDataToEndOfFile(), as: UTF8.self)
                        if p.terminationStatus == 0 {
                            cont.resume()
                        } else {
                            cont.resume(throwing: Failure(message: lastLine(err) ?? "ssh: \(p.terminationStatus)"))
                        }
                    }
                    box.process = process
                    do { try process.run() } catch { cont.resume(throwing: error) }
                }
            } onCancel: {
                box.terminate()
            }
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: localURL)
            throw CancellationError()
        }
    }

    /// Загрузить файл в `remoteDirectory/name`: сначала во временный файл, затем атомарно переименовать.
    public static func upload(_ ssh: SSHInvocation, localURL: URL, remoteDirectory: String, name: String,
                              progress: @escaping @Sendable (Int64) -> Void) async throws {
        let target = join(remoteDirectory, name)
        let temp = join(remoteDirectory, ".\(name).relaya-part")
        let command = "cat > \(quote(temp)) && mv -f -- \(quote(temp)) \(quote(target)) || { rm -f -- \(quote(temp)); exit 1; }"
        let input = try FileHandle(forReadingFrom: localURL)
        let box = ProcessBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let process = Process()
                ssh.configure(process, command: command)
                let stdin = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderr
                let writer = stdin.fileHandleForWriting
                let errReader = stderr.fileHandleForReading
                process.terminationHandler = { p in
                    let err = String(decoding: errReader.readDataToEndOfFile(), as: UTF8.self)
                    if p.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: Failure(message: lastLine(err) ?? "ssh: \(p.terminationStatus)"))
                    }
                }
                box.process = process
                do { try process.run() } catch { cont.resume(throwing: error); return }
                // Запись в pipe блокирует — отдельный поток. SIGPIPE игнорируется приложением.
                let counter = Counter()
                Thread.detachNewThread {
                    defer { try? writer.close(); try? input.close() }
                    while !box.cancelled {
                        guard let chunk = try? input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                        do { try writer.write(contentsOf: chunk) } catch { break }
                        progress(counter.add(chunk.count))
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    // MARK: - Помощники

    final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _process: Process?
        private var _cancelled = false

        var process: Process? {
            get { lock.withLock { _process } }
            set { lock.withLock { _process = newValue } }
        }
        var cancelled: Bool { lock.withLock { _cancelled } }

        func terminate() {
            lock.withLock {
                _cancelled = true
                if _process?.isRunning == true { _process?.terminate() }
            }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        func add(_ n: Int) -> Int64 { lock.withLock { value += Int64(n); return value } }
    }

    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    static func lastLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}
