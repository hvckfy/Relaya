import Foundation

/// Нечёткий поиск для палитры ⌘K: буквы запроса по порядку, бонус за начало слова и подряд идущие.
/// Возвращает nil, если не совпало; больше — лучше.
public enum FuzzyMatch {
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var score = 0, qi = 0, prev = -2
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += 1
            if i == prev + 1 { score += 5 }
            if i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber) { score += 8 }
            prev = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Подстрока целиком — сильнее, особенно с начала слова; короткие названия — выше.
        let lower = text.lowercased()
        if let r = lower.range(of: String(q)) {
            let atWordStart = r.lowerBound == lower.startIndex
                || !(lower[lower.index(before: r.lowerBound)].isLetter || lower[lower.index(before: r.lowerBound)].isNumber)
            score += atWordStart ? 20 : 5
        }
        return score * 100 - t.count
    }

    /// Лучшее совпадение среди нескольких полей (название, адрес, метки…).
    public static func score(_ query: String, in fields: [String]) -> Int? {
        fields.compactMap { score(query, in: $0) }.max()
    }
}
