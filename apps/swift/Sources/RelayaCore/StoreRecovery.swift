import Foundation

/// Нечитаемый JSON-файл данных (сниппеты, туннели, столы) не превращается в пустой список, который потом
/// сохранится поверх: файл откладывается рядом как `имя.unreadable-<дата>.json`, а интерфейс сообщает об этом.
public enum StoreRecovery {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var moved: [String] = []
    /// Файлы, которые есть, но не прочитались (права, ошибка ввода-вывода): сохранять поверх нельзя.
    nonisolated(unsafe) private static var unreadable: Set<String> = []

    /// Ошибка записи: файл не прочитан при загрузке, перезапись затёрла бы данные.
    public struct ReadFailed: LocalizedError {
        public let path: String
        public var errorDescription: String? {
            L("Файл %@ не удалось прочитать — изменения не сохранены, чтобы не затереть его. Проверьте права доступа и перезапустите Relaya.", path)
        }
    }

    /// Вызывается перед сохранением: бросает, если файл при загрузке не прочитался.
    public static func checkWritable(_ url: URL) throws {
        if lock.withLock({ unreadable.contains(url.path) }) { throw ReadFailed(path: url.path) }
    }

    /// Отложенные файлы с прошлого вызова (для окна-предупреждения); список очищается.
    public static func takeMoved() -> [String] {
        lock.withLock {
            defer { moved = [] }; return moved
        }
    }

    /// Прочитать список: нет файла — `missing`; не разбирается — файл откладывается и возвращается `[]`;
    /// не читается — `[]`, и сохранение поверх запрещено (`checkWritable`).
    public static func load<T: Decodable>(_ type: [T].Type, from url: URL, missing: [T] = []) -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Файл есть, но не читается — не подставляем примеры и запрещаем сохранение поверх.
            lock.withLock { _ = unreadable.insert(url.path) }
            return []
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [] }
        if let list = try? JSONDecoder().decode(type, from: data) { return list }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(f.string(from: Date())).json")
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
            lock.withLock { moved.append(aside.path) }
        }
        return []
    }
}
