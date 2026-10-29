/// Построчный diff (LCS) для превью изменений конфига.
public enum LineDiff {
    public enum Kind: Sendable { case same, added, removed }

    public struct Line: Sendable, Hashable {
        public var kind: Kind
        public var text: String
    }

    public static func diff(_ old: [String], _ new: [String]) -> [Line] {
        let n = old.count, m = new.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                out.append(Line(kind: .same, text: old[i])); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                out.append(Line(kind: .added, text: new[j])); j += 1
            } else {
                out.append(Line(kind: .removed, text: old[i])); i += 1
            }
        }
        return out
    }
}
