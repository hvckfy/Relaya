import Foundation

/// Файл или папка на сервере.
public struct RemoteFile: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var isDirectory: Bool
    public var isLink: Bool
    public var size: Int64
    public var permissions: String
    public var modified: String

    public init(name: String, isDirectory: Bool, isLink: Bool = false, size: Int64 = 0,
                permissions: String = "", modified: String = "") {
        self.name = name
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.size = size
        self.permissions = permissions
        self.modified = modified
    }
}

/// SFTP через системный `/usr/bin/sftp` в пакетном режиме: те же ~/.ssh/config, ключи и агент.
/// Пароль — только через askpass из Keychain.
public struct SFTPClient: Sendable {
    public var alias: String
    public var password: KeyInstaller.SecretRef?
    public var askpassExecutable: String

    public init(alias: String, password: KeyInstaller.SecretRef?, askpassExecutable: String) {
        self.alias = alias
        self.password = password
        self.askpassExecutable = askpassExecutable
    }

    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Выполняет команды sftp; ошибка любой из них прерывает пакет.
    @discardableResult
    public func run(_ commands: [String]) async throws -> String {
        var args = ["-q", "-b", "-", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15"]
        var env: [String: String] = [:]
        if let password {
            env = KeyInstaller(askpassExecutable: askpassExecutable).askpassEnvironment(password)
            args += KeyInstaller.passwordOnlyOptions
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        let r = try await ProcessRunner.run("/usr/bin/sftp", args + [alias],
                                            environment: env, input: commands.joined(separator: "\n") + "\n")
        guard r.succeeded else {
            let lines = r.stderr.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("sftp>") }
            throw Failure(message: lines.last ?? L("sftp завершился с кодом %@", "\(r.status)"))
        }
        return r.stdout
    }

    public func home() async throws -> String {
        let out = try await run(["pwd"])
        for line in out.split(whereSeparator: \.isNewline) {
            if let r = line.range(of: "Remote working directory: ") { return String(line[r.upperBound...]) }
        }
        return "/"
    }

    public func list(_ path: String) async throws -> [RemoteFile] {
        let out = try await run(["cd \(Self.quote(path))", "ls -la"])
        return Self.parseListing(out)
    }

    public func download(_ remotePath: String, to localDirectory: URL, recursive: Bool) async throws {
        try await run(["lcd \(Self.quote(localDirectory.path))",
                       "get \(recursive ? "-r " : "")\(Self.quote(remotePath))"])
    }

    public func upload(_ localPath: String, to remoteDirectory: String) async throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir)
        try await run(["cd \(Self.quote(remoteDirectory))", "put \(isDir.boolValue ? "-r " : "")\(Self.quote(localPath))"])
    }

    public func makeDirectory(_ path: String) async throws {
        try await run(["mkdir \(Self.quote(path))"])
    }

    /// Удаляет файл или пустую папку (рекурсивно sftp не умеет — это защищает от случайностей).
    public func remove(_ path: String, isDirectory: Bool) async throws {
        try await run([(isDirectory ? "rmdir " : "rm ") + Self.quote(path)])
    }

    public func rename(_ from: String, to: String) async throws {
        try await run(["rename \(Self.quote(from)) \(Self.quote(to))"])
    }

    // MARK: - Разбор и пути

    /// Строки `ls -la` из sftp: `drwxr-xr-x  2 root root 4096 Oct 29 12:00 name with spaces`.
    public static func parseListing(_ output: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let first = line.first, "-dlcbps".contains(first) else { continue }
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 9 else { continue }
            var name = parts[8]
            if first == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { continue }
            files.append(RemoteFile(name: name, isDirectory: first == "d", isLink: first == "l",
                                    size: Int64(parts[4]) ?? 0, permissions: parts[0],
                                    modified: "\(parts[5]) \(parts[6]) \(parts[7])"))
        }
        return files.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Аргумент команды sftp в кавычках.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let p = String(trimmed[..<slash])
        return p.isEmpty ? "/" : p
    }
}
