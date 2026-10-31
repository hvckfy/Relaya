import Foundation
import RelayaRust

/// Нечёткий поиск для палитры ⌘K: буквы запроса по порядку, бонус за начало слова и подряд идущие.
/// Логика — в общем Rust-ядре (`core/src/fuzzy.rs`), здесь — Swift-фасад.
public enum FuzzyMatch {
    public static func score(_ query: String, in text: String) -> Int? {
        fuzzyScore(query: query, text: text).map(Int.init)
    }

    public static func score(_ query: String, in fields: [String]) -> Int? {
        fuzzyScoreFields(query: query, fields: fields).map(Int.init)
    }
}
