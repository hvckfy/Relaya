import Foundation
import RelayaRust

/// Построчный diff (LCS) для превью изменений конфига. Логика — в Rust-ядре (`core/src/diff.rs`).
public enum LineDiff {
    public enum Kind: Sendable { case same, added, removed }

    public struct Line: Sendable, Hashable {
        public var kind: Kind
        public var text: String
    }

    public static func diff(_ old: [String], _ new: [String]) -> [Line] {
        lineDiff(old: old, new: new).map { l in
            Line(kind: { switch l.kind { case .same: .same; case .added: .added; case .removed: .removed } }(), text: l.text)
        }
    }
}
