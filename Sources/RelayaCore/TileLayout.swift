import Foundation
import CoreGraphics

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

    /// Прямоугольники плиток внутри `rect` (дети делят место поровну — как при первом показе).
    public func frames(in rect: CGRect) -> [ID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .row(let c):
            let w = rect.width / CGFloat(c.count)
            return c.enumerated().reduce(into: [:]) { acc, e in
                acc.merge(e.element.frames(in: CGRect(x: rect.minX + w * CGFloat(e.offset), y: rect.minY,
                                                      width: w, height: rect.height))) { $1 }
            }
        case .column(let c):
            let h = rect.height / CGFloat(c.count)
            return c.enumerated().reduce(into: [:]) { acc, e in
                acc.merge(e.element.frames(in: CGRect(x: rect.minX, y: rect.minY + h * CGFloat(e.offset),
                                                      width: rect.width, height: h))) { $1 }
            }
        }
    }

    /// Соседняя плитка в направлении `edge` (для ⌥⌘стрелок): ближайшая по центру среди лежащих в ту сторону.
    public func neighbor(of id: ID, toward edge: Edge) -> ID? {
        let f = frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let me = f[id] else { return nil }
        let eps = 1e-9
        let candidates = f.filter { other, r in
            guard other != id else { return false }
            switch edge {
            case .left: return r.maxX <= me.minX + eps && r.maxY > me.minY && r.minY < me.maxY
            case .right: return r.minX >= me.maxX - eps && r.maxY > me.minY && r.minY < me.maxY
            case .top: return r.maxY <= me.minY + eps && r.maxX > me.minX && r.minX < me.maxX
            case .bottom: return r.minY >= me.maxY - eps && r.maxX > me.minX && r.minX < me.maxX
            }
        }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = r.midX - me.midX
            let dy = r.midY - me.midY
            return dx * dx + dy * dy
        }
        return candidates.min { distance($0.value) < distance($1.value) }?.key
    }

    /// Та же раскладка с другими идентификаторами (вкладки ↔ алиасы хостов); nil — плитка выпадает.
    public func map<T: Hashable & Sendable>(_ f: (ID) -> T?) -> TileLayout<T>? {
        switch self {
        case .leaf(let id): return f(id).map { .leaf($0) }
        case .row(let c):
            let m = c.compactMap { $0.map(f) }
            return m.isEmpty ? nil : m.count == 1 ? m[0] : .row(m)
        case .column(let c):
            let m = c.compactMap { $0.map(f) }
            return m.isEmpty ? nil : m.count == 1 ? m[0] : .column(m)
        }
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

extension TileLayout: Codable where ID: Codable {}
