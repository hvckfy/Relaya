import Foundation

/// Адреса вида `localhost:3000`, `127.0.0.1:8080`, `0.0.0.0:5173`, `[::1]:9000` в выводе терминала —
/// это порты на сервере, которые можно открыть у себя через временный туннель.
public enum LocalPorts {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:https?://)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})\b"#,
        options: [.caseInsensitive])

    /// Порты в порядке появления, без повторов; только 1…65535 и не 22.
    public static func find(in text: String) -> [Int] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<Int>()
        return pattern.matches(in: text, range: range).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text), let port = Int(text[r]),
                  (1...65535).contains(port), port != 22, seen.insert(port).inserted else { return nil }
            return port
        }
    }
}
