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

    /// Скачать `remotePath` в `localURL`: сначала в `.имя.part` рядом, каждая запись проверяется,
    /// и только после успеха файл переименовывается. Существующий `localURL` до этого не трогается.
    public static func download(_ ssh: SSHInvocation, remotePath: String, to localURL: URL,
                                progress: @escaping @Sendable (Int64) -> Void) async throws {
        let part = localURL.deletingLastPathComponent().appending(path: ".\(localURL.lastPathComponent).\(UUID().uuidString.prefix(8)).part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
            throw Failure(message: L("Не удалось создать файл %@", part.path))
        }
        let out = try FileHandle(forWritingTo: part)
        let box = ProcessBox()
        let writeError = ErrorBox()
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
                    // Диск полон или файл недоступен — останавливаем ssh, а не теряем данные молча.
                    let write: (Data) -> Void = { data in
                        guard writeError.error == nil else { return }
                        do {
                            try out.write(contentsOf: data)
                            progress(counter.add(data.count))
                        } catch {
                            writeError.error = error
                            box.terminate()
                        }
                    }
                    reader.readabilityHandler = { h in
                        let data = h.availableData
                        guard !data.isEmpty else { h.readabilityHandler = nil; return }
                        write(data)
                    }
                    process.terminationHandler = { p in
                        reader.readabilityHandler = nil
                        let rest = reader.readDataToEndOfFile()
                        if !rest.isEmpty { write(rest) }
                        let err = String(decoding: errReader.readDataToEndOfFile(), as: UTF8.self)
                        if let e = writeError.error {
                            cont.resume(throwing: Failure(message: L("Ошибка записи на диск: %@", e.localizedDescription)))
                        } else if p.terminationStatus == 0 {
                            cont.resume()
                        } else {
                            cont.resume(throwing: Failure(message: SSHErrorText.describe(err, fallback: "ssh: \(p.terminationStatus)")))
                        }
                    }
                    if box.cancelled { cont.resume(throwing: CancellationError()); return }
                    box.process = process
                    do { try process.run() } catch { cont.resume(throwing: error) }
                }
            } onCancel: {
                box.terminate()
            }
            try out.synchronize()
            try out.close()
            if Task.isCancelled { throw CancellationError() }
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: part)
            } else {
                try FileManager.default.moveItem(at: part, to: localURL)
            }
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    /// Загрузить файл в `remoteDirectory/name`: во временный файл с уникальным именем, проверить размер,
    /// перенести права существующего файла и только потом атомарно заменить. Обрыв, отмена или ошибка чтения
    /// оставляют оригинал на месте.
    public static func upload(_ ssh: SSHInvocation, localURL: URL, remoteDirectory: String, name: String,
                              progress: @escaping @Sendable (Int64) -> Void) async throws {
        if Task.isCancelled { throw CancellationError() }
        let target = join(remoteDirectory, name)
        let temp = join(remoteDirectory, ".\(name).\(UUID().uuidString.prefix(8).lowercased()).relaya-part")
        let size = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? -1
        let (t, g) = (quote(temp), quote(target))
        let command = "cat > \(t) || { rm -f -- \(t); exit 1; }; "
            + "if [ \"$(wc -c < \(t) | tr -d ' ')\" != \"\(size)\" ]; then rm -f -- \(t); echo 'relaya: size mismatch, upload incomplete' >&2; exit 1; fi; "
            + "if [ -e \(g) ]; then chmod --reference=\(g) \(t) 2>/dev/null || chmod \"$(stat -f %Lp \(g) 2>/dev/null || stat -c %a \(g))\" \(t) 2>/dev/null; fi; "
            + "mv -f -- \(t) \(g) || { rm -f -- \(t); exit 1; }"
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
                let readError = ErrorBox()
                process.terminationHandler = { p in
                    let err = String(decoding: errReader.readDataToEndOfFile(), as: UTF8.self)
                    if let e = readError.error {
                        cont.resume(throwing: Failure(message: L("Не удалось прочитать файл: %@", e.localizedDescription)))
                    } else if p.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: Failure(message: SSHErrorText.describe(err, fallback: "ssh: \(p.terminationStatus)")))
                    }
                }
                if box.cancelled { try? input.close(); cont.resume(throwing: CancellationError()); return }
                box.process = process
                do { try process.run() } catch { try? input.close(); cont.resume(throwing: error); return }
                // Запись в pipe блокирует — отдельный поток. SIGPIPE игнорируется приложением.
                // Ошибка чтения не превращается в «конец файла»: размер не сойдётся, и сервер оставит оригинал.
                let counter = Counter()
                Thread.detachNewThread {
                    defer { try? writer.close(); try? input.close() }
                    while !box.cancelled {
                        let chunk: Data
                        do {
                            guard let c = try input.read(upToCount: 256 * 1024), !c.isEmpty else { break }
                            chunk = c
                        } catch {
                            readError.error = error
                            box.terminate()
                            break
                        }
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

    final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _error: Error?
        var error: Error? {
            get { lock.withLock { _error } }
            set { lock.withLock { _error = newValue } }
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
