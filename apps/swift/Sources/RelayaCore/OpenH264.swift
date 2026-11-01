import Foundation
import RelayaRust

/// Кодек H.264 от Cisco (OpenH264) для встроенного RDP — скачивается только по включению пользователя
/// (лицензия Cisco разрешает распространение их двоичного файла, но не наш). Проверки — в ядре: sha256 архива,
/// sha256 библиотеки перед каждым использованием, а FreeRDP грузит проверенную копию (checked_copy).
public enum OpenH264 {
    public static var info: OpenH264Info? { openh264CurrentPlatform().map { openh264Info(platform: $0) } }

    /// Текст лицензии Cisco — показать до включения.
    public static var notice: String { info?.notice ?? "" }

    public static var libraryURL: URL? { info.map { RelayaPaths.supportDirectory.appending(path: $0.fileName) } }

    /// Включён и файл тот, что закреплён.
    public static var isInstalled: Bool { libraryURL.map { openh264Verify(path: $0.path) } ?? false }

    /// Путь для RdpConfig.h264LibraryPath; nil — H.264 выключен.
    public static var libraryPath: String? { isInstalled ? libraryURL?.path : nil }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    /// Скачать архив Cisco (https), проверить, распаковать в папку данных и проверить библиотеку.
    public static func install() async throws {
        guard let info, let platform = openh264CurrentPlatform(), let dest = libraryURL else {
            throw Failure(errorDescription: L("Для этой платформы кодека нет."))
        }
        // Адрес из ядра уже https (S4), целостность держит закреплённый sha256.
        guard let url = URL(string: info.url) else { throw Failure(errorDescription: L("Для этой платформы кодека нет.")) }
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, openh264VerifyArchive(path: archive.path, platform: platform) else {
            throw Failure(errorDescription: L("Архив кодека не прошёл проверку — не устанавливаю."))
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.deletingLastPathComponent().appending(path: ".\(info.fileName).part")
        try? FileManager.default.removeItem(at: tmp)
        try decompress(archive, to: tmp)
        guard openh264Verify(path: tmp.path) else {
            try? FileManager.default.removeItem(at: tmp)
            throw Failure(errorDescription: L("Библиотека кодека не прошла проверку — не устанавливаю."))
        }
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// bunzip2 в файл: двоичный вывод нельзя гнать через строку.
    private static func decompress(_ archive: URL, to file: URL) throws {
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bunzip2")
        p.arguments = ["-c", archive.path]
        p.standardOutput = try FileHandle(forWritingTo: file)
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(errorDescription: L("Не удалось распаковать кодек.")) }
    }

    /// Выключить: удалить библиотеку.
    public static func remove() throws {
        if let url = libraryURL, FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
