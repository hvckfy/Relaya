import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }
    /// stderr, а если он пуст — stdout: для сообщений об ошибке.
    public var message: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : e
    }
}

/// Запуск утилит (`ssh`, `ssh-keygen`, `ssh-add`, `sftp`) без shell — аргументы не интерпретируются.
/// stdout и stderr читаются параллельно с работой процесса (иначе вывод больше буфера pipe, ~64 КБ, вешает его),
/// stdin пишется в фоне; отмена задачи завершает процесс.
public enum ProcessRunner {
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        input: String? = nil,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        let box = StreamTransfer.ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                }
                let out = Pipe(), err = Pipe(), inp = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = input == nil ? FileHandle.nullDevice : inp

                let stdout = Buffer(), stderr = Buffer()
                let eof = DispatchGroup()
                for (pipe, buffer) in [(out, stdout), (err, stderr)] {
                    eof.enter()
                    pipe.fileHandleForReading.readabilityHandler = { h in
                        let data = h.availableData
                        if data.isEmpty {
                            h.readabilityHandler = nil
                            eof.leave()
                        } else {
                            buffer.append(data)
                        }
                    }
                }
                process.terminationHandler = { p in
                    eof.notify(queue: .global()) {
                        continuation.resume(returning: ProcessResult(status: p.terminationStatus,
                                                                     stdout: stdout.string, stderr: stderr.string))
                    }
                }
                if box.cancelled {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                box.process = process
                do {
                    try process.run()
                } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if let timeout {
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                        if process.isRunning { process.terminate() }
                    }
                }
                if let input {
                    let writer = inp.fileHandleForWriting
                    DispatchQueue.global().async {
                        try? writer.write(contentsOf: Data(input.utf8))
                        try? writer.close()
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
