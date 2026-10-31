import Foundation
import RelayaRust

/// Построчная модель `~/.ssh/config` для правок. Логика — в Rust-ядре (`core/src/ssh_config.rs`).
///
/// Меняет только блок нужного хоста: остальной файл, комментарии и незнакомые
/// директивы внутри блока сохраняются как есть.
public struct SSHConfigDocument: Sendable {
    public private(set) var text: String

    public init(text: String) {
        // Как раньше: текст нормализуется к виду «строки + завершающий перевод строки».
        let lines = configLines(text: text)
        self.text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public var lines: [String] { configLines(text: text) }

    /// Где лежит блок хоста.
    public struct Block: Sendable, Equatable {
        /// Строки блока, включая комментарий `# relaya:` над ним.
        public var range: Range<Int>
        /// Индекс строки `Host`.
        public var hostLine: Int
        /// Блок объявлен вместе с другими алиасами (`Host a b`) — правка разорвала бы его.
        public var isShared: Bool
    }

    public func block(for alias: String) -> Block? {
        configBlock(text: text, alias: alias).map {
            Block(range: Int($0.start)..<Int($0.end), hostLine: Int($0.hostLine), isShared: $0.isShared)
        }
    }

    /// Сменить только метаданные Relaya (`# relaya:` — группа, метки, цвет, ОС, tmux), не перерисовывая директивы блока.
    /// Подходит и для общих блоков `Host a b`.
    public mutating func setMeta(of host: SSHHost) throws {
        text = try configSetMeta(text: text, alias: host.alias, group: host.group, tags: host.tags, color: host.color,
                                 os: host.os?.rust, tmux: host.tmux)
    }

    /// Строки, которые сейчас занимает хост (для превью).
    public func currentLines(for alias: String) -> [String] { configCurrentLines(text: text, alias: alias) }

    /// Строки блока после сохранения `host`. Незнакомые директивы из старого блока сохраняются.
    public func renderedLines(for host: SSHHost, replacing originalAlias: String?) -> [String] {
        configRenderedLines(text: text, host: host.rust, originalAlias: originalAlias)
    }

    public enum EditError: Error, Equatable, LocalizedError {
        case aliasTaken(String)
        case sharedBlock(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .aliasTaken(let a): L("Хост «%@» уже есть в ~/.ssh/config", "\(a)")
            case .sharedBlock(let a): L("«%@» объявлен вместе с другими алиасами — отредактируйте ~/.ssh/config вручную", "\(a)")
            case .notFound(let a): L("Хост «%@» не найден в ~/.ssh/config", "\(a)")
            }
        }
    }

    /// Добавляет хост (`originalAlias == nil`) или заменяет блок существующего.
    public mutating func upsert(_ host: SSHHost, originalAlias: String?) throws {
        // Те же проверки, что в ядре, — чтобы ошибки были типизированными, а не текстом.
        if host.alias != originalAlias, block(for: host.alias) != nil { throw EditError.aliasTaken(host.alias) }
        if let originalAlias {
            guard let b = block(for: originalAlias) else { throw EditError.notFound(originalAlias) }
            guard !b.isShared else { throw EditError.sharedBlock(originalAlias) }
        }
        text = try configUpsert(text: text, host: host.rust, originalAlias: originalAlias)
    }

    public mutating func remove(alias: String) throws {
        guard let b = block(for: alias) else { throw EditError.notFound(alias) }
        guard !b.isShared else { throw EditError.sharedBlock(alias) }
        text = try configRemove(text: text, alias: alias)
    }

    /// Заменить блок хоста готовыми строками или добавить их в конец (для синхронизации).
    public mutating func replaceOrAppend(alias: String, with block: [String]) {
        text = configMerge(local: text, incoming: block.joined(separator: "\n") + "\n")
    }
}
