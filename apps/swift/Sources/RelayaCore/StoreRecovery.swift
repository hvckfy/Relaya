import Foundation

/// Нечитаемый JSON-файл данных (сниппеты, туннели, столы) не превращается в пустой список, который потом
/// сохранится поверх: файл откладывается рядом как `имя.unreadable-<дата>.json`, а интерфейс сообщает об этом.
public enum StoreRecovery {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var moved: [String] = []

    /// Отложенные файлы с прошлого вызова (для окна-предупреждения); список очищается.
    public static func takeMoved() -> [String] {
        lock.withLock { defer { moved = [] }; return moved }
    }

    /// Прочитать список: нет файла — `missing`, не читается — файл откладывается и возвращается `[]`.
    public static func load<T: Decodable>(_ type: [T].Type, from url: URL, missing: [T] = []) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return missing }
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
