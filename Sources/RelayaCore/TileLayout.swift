import Foundation

/// Раскладка терминалов плитками: дерево разбиений без наложений.
/// `row` — дети рядом по горизонтали, `column` — друг под другом.
public indirect enum TileLayout<ID: Hashable & Sendable>: Equatable, Sendable {
    case leaf(ID)
    case row([TileLayout])
    case column([TileLayout])

    public enum Edge: Sendable { case left, right, top, bottom }

    public var ids: [ID] {
        switch self {
        case .leaf(let id): [id]
        case .row(let c), .column(let c): c.flatMap(\.ids)
        }
    }

    /// По умолчанию — ряды по два; нечётный последний занимает всю ширину.
    public static func automatic(_ ids: [ID]) -> TileLayout? {
        guard !ids.isEmpty else { return nil }
        var layout = TileLayout.leaf(ids[0])
        for id in ids.dropFirst() { layout = layout.appending(id) }
        return layout
    }

    /// Новая плитка: дополняет последний неполный ряд или начинает новый снизу.
    public func appending(_ id: ID) -> TileLayout {
        switch self {
        case .leaf: return .row([self, .leaf(id)])
        case .row(let c) where c.count < 2: return .row(c + [.leaf(id)])
        case .row: return .column([self, .leaf(id)])
        case .column(var rows):
            switch rows.last {
            case .leaf(let last)?: rows[rows.count - 1] = .row([.leaf(last), .leaf(id)])
            case .row(let r)? where r.count < 2: rows[rows.count - 1] = .row(r + [.leaf(id)])
            default: rows.append(.leaf(id))
            }
            return .column(rows)
        }
    }

    public func removing(_ id: ID) -> TileLayout? {
        switch self {
        case .leaf(let x): return x == id ? nil : self
        case .row(let c): return Self.make(row: true, c.compactMap { $0.removing(id) })
        case .column(let c): return Self.make(row: false, c.compactMap { $0.removing(id) })
        }
    }

    /// Вставить `id` у края плитки `target` (nil — у края всей раскладки, на всю ширину/высоту).
    public func inserting(_ id: ID, at edge: Edge, of target: ID?) -> TileLayout {
        let base = removing(id) ?? .leaf(id)
        guard base.ids != [id] else { return base }
        let row = edge == .left || edge == .right
        let before = edge == .left || edge == .top
        guard let target, base.ids.contains(target) else {
            return Self.join(base, .leaf(id), row: row, before: before)
        }
        return base.replacingLeaf(target) { leaf in Self.join(leaf, .leaf(id), row: row, before: before) }
    }

    /// Поменять две плитки местами.
    public func swapping(_ a: ID, _ b: ID) -> TileLayout {
        switch self {
        case .leaf(let x): return .leaf(x == a ? b : x == b ? a : x)
        case .row(let c): return .row(c.map { $0.swapping(a, b) })
        case .column(let c): return .column(c.map { $0.swapping(a, b) })
        }
    }

    /// Привести к списку открытых: закрытые убрать, новые добавить.
    public func synced(with ids: [ID]) -> TileLayout? {
        var layout: TileLayout? = self
        for id in self.ids where !ids.contains(id) { layout = layout?.removing(id) }
        for id in ids where !(layout?.ids.contains(id) ?? false) {
            layout = layout?.appending(id) ?? .leaf(id)
        }
        return layout
    }

    // MARK: - Внутреннее

    private func replacingLeaf(_ target: ID, with f: (TileLayout) -> TileLayout) -> TileLayout {
        switch self {
        case .leaf(let x): return x == target ? f(self) : self
        case .row(let c): return Self.make(row: true, c.map { $0.replacingLeaf(target, with: f) }) ?? self
        case .column(let c): return Self.make(row: false, c.map { $0.replacingLeaf(target, with: f) }) ?? self
        }
    }

    private static func join(_ a: TileLayout, _ b: TileLayout, row: Bool, before: Bool) -> TileLayout {
        make(row: row, before ? [b, a] : [a, b])!
    }

    /// Собирает разбиение: один ребёнок — сам по себе, вложенное той же ориентации — сплющивается.
    private static func make(row: Bool, _ children: [TileLayout]) -> TileLayout? {
        var flat: [TileLayout] = []
        for c in children {
            switch c {
            case .row(let inner) where row: flat += inner
            case .column(let inner) where !row: flat += inner
            default: flat.append(c)
            }
        }
        switch flat.count {
        case 0: return nil
        case 1: return flat[0]
        default: return row ? .row(flat) : .column(flat)
        }
    }
}
