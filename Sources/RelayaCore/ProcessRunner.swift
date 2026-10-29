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

/// Запуск утилит (`ssh`, `ssh-keygen`, `ssh-add`) без shell — аргументы не интерпретируются.
public enum ProcessRunner {
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        input: String? = nil
    ) async throws -> ProcessResult {
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

            let outHandle = out.fileHandleForReading
            let errHandle = err.fileHandleForReading
            process.terminationHandler = { p in
                // Вывод этих утилит короткий и помещается в буфер pipe.
                let o = String(decoding: outHandle.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: errHandle.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: ProcessResult(status: p.terminationStatus, stdout: o, stderr: e))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            if let input {
                inp.fileHandleForWriting.write(Data(input.utf8))
                try? inp.fileHandleForWriting.close()
            }
        }
    }
}
