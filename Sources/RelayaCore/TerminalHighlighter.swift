import Foundation

/// Правило подсветки вывода терминала.
public struct HighlightRule: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    /// Текст или регулярное выражение.
    public var pattern: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    /// Индекс цвета ANSI 0–15: цвет берётся из схемы терминала, поэтому подходит к любой теме.
    public var color: Int
    public var bold: Bool
    public var enabled: Bool

    public init(name: String, pattern: String, isRegex: Bool = true, caseSensitive: Bool = false,
                color: Int, bold: Bool = false, enabled: Bool = true) {
        self.name = name
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.color = color
        self.bold = bold
        self.enabled = enabled
    }

    public static let defaults: [HighlightRule] = [
        HighlightRule(name: "Ошибки", pattern: #"\b(error|errors|failed|failure|fatal|panic|denied|refused|critical|exception)\b"#,
                      color: 9, bold: true),
        HighlightRule(name: "Предупреждения", pattern: #"\b(warn|warning|warnings|deprecated)\b"#, color: 11),
        HighlightRule(name: "Успех", pattern: #"\b(ok|success|successful|succeeded|done|passed|active \(running\))\b"#, color: 10),
        HighlightRule(name: "IP-адреса", pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b"#, color: 14),
        HighlightRule(name: "URL", pattern: #"\bhttps?://[^\s'"<>]+"#, color: 12),
        HighlightRule(name: "Даты и время", pattern: #"\b\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?\b"#,
                      color: 13, enabled: false),
    ]

    public func compiled() -> NSRegularExpression? {
        guard enabled, !pattern.isEmpty else { return nil }
        let source = isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        return try? NSRegularExpression(pattern: source, options: caseSensitive ? [] : [.caseInsensitive])
    }
}

/// Добавляет ANSI-цвета к совпадениям в выводе терминала.
///
/// Не трогает escape-последовательности, текст, который сервер уже раскрасил сам,
/// и полноэкранные программы (vim, top, mc) — в альтернативном экране подсветка выключена.
public struct TerminalHighlighter {
    private var rules: [(NSRegularExpression, HighlightRule)] = []
    private var inAltScreen = false
    /// Сервер сейчас выводит цветной текст (SGR с цветом переднего плана).
    private var remoteColored = false
    /// Хвост незаконченной escape-последовательности из прошлого куска.
    private var carry = ""

    public init(rules: [HighlightRule]) {
        setRules(rules)
    }

    public mutating func setRules(_ rules: [HighlightRule]) {
        self.rules = rules.compactMap { r in r.compiled().map { ($0, r) } }
    }

    public var isActive: Bool { !rules.isEmpty }

    /// Возвращает и сбрасывает отложенный хвост (перед выводом сырых байтов).
    public mutating func flush() -> String {
        defer { carry = "" }
        return carry
    }

    public mutating func process(_ chunk: String) -> String {
        let scalars = Array((carry + chunk).unicodeScalars)
        carry = ""
        var out = String.UnicodeScalarView()
        var plain = String.UnicodeScalarView()
        var i = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            let text = String(plain)
            out.append(contentsOf: (inAltScreen || remoteColored ? text : highlight(text)).unicodeScalars)
            plain.removeAll()
        }

        while i < scalars.count {
            guard scalars[i] == "\u{1B}" else {
                plain.append(scalars[i])
                i += 1
                continue
            }
            flushPlain()
            guard let end = escapeEnd(scalars, from: i) else {
                // Последовательность оборвалась на границе куска — доделаем со следующим.
                carry = String(String.UnicodeScalarView(scalars[i...]))
                break
            }
            let seq = String(String.UnicodeScalarView(scalars[i..<end]))
            track(seq)
            out.append(contentsOf: seq.unicodeScalars)
            i = end
        }
        flushPlain()
        return String(out)
    }

    /// Конец escape-последовательности, начинающейся с ESC в позиции `start`, или nil, если она не закончена.
    private func escapeEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        var i = start + 1
        guard i < s.count else { return nil }
        switch s[i] {
        case "[":
            i += 1
            while i < s.count {
                if (0x40...0x7E).contains(s[i].value) { return i + 1 }
                i += 1
            }
            return nil
        case "]", "P", "_", "^":
            // OSC/DCS: до BEL или ESC \
            i += 1
            while i < s.count {
                if s[i] == "\u{07}" { return i + 1 }
                if s[i] == "\u{1B}" {
                    guard i + 1 < s.count else { return nil }
                    if s[i + 1] == "\\" { return i + 2 }
                }
                i += 1
            }
            return nil
        case "(", ")", "*", "+", "#", "%":
            return i + 1 < s.count ? i + 2 : nil
        default:
            return i + 1
        }
    }

    private mutating func track(_ seq: String) {
        guard seq.hasPrefix("\u{1B}[") else { return }
        let body = seq.dropFirst(2)
        if body.hasPrefix("?") {
            let modes = body.dropFirst().dropLast().split(separator: ";")
            if modes.contains(where: { ["1049", "47", "1047"].contains($0) }) {
                if seq.hasSuffix("h") { inAltScreen = true }
                if seq.hasSuffix("l") { inAltScreen = false }
            }
            return
        }
        guard seq.hasSuffix("m") else { return }
        let params = body.dropLast().split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var k = 0
        while k < params.count {
            let p = params[k]
            switch p {
            case 0, 39: remoteColored = false
            case 30...37, 90...97: remoteColored = true
            case 38:
                remoteColored = true
                k += params.indices.contains(k + 1) && params[k + 1] == 5 ? 2 : 4
            default: break
            }
            k += 1
        }
    }

    private func highlight(_ text: String) -> String {
        let ns = text as NSString
        var taken: [(NSRange, HighlightRule)] = []
        for (regex, rule) in rules {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                if !taken.contains(where: { NSIntersectionRange($0.0, m.range).length > 0 }) {
                    taken.append((m.range, rule))
                }
            }
        }
        guard !taken.isEmpty else { return text }
        taken.sort { $0.0.location < $1.0.location }
        var result = ""
        var pos = 0
        for (range, rule) in taken {
            result += ns.substring(with: NSRange(location: pos, length: range.location - pos))
            let code = rule.color < 8 ? 30 + rule.color : 90 + (rule.color - 8)
            result += "\u{1B}[\(rule.bold ? "1;" : "")\(code)m" + ns.substring(with: range) + "\u{1B}[\(rule.bold ? "22;" : "")39m"
            pos = range.location + range.length
        }
        result += ns.substring(from: pos)
        return result
    }
}
