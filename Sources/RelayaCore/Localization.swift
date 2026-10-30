import Foundation

/// Перевод строки интерфейса. Ключ — русский текст (язык разработки), переводы лежат
/// в `Contents/Resources/<язык>.lproj/Localizable.strings` бандла приложения.
/// Подстановки — `%@`, аргументы передаются строками.
public func L(_ key: String, _ args: String...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return format }
    return String(format: format, arguments: args.map { $0 as CVarArg })
}
