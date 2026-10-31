import Foundation
import CoreGraphics
import RelayaRust

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

    // Операции над деревом — в Rust-ядре (`core/src/tile_layout.rs`), общем с Windows-клиентом.
    // Идентификаторы туда уходят как строки `t0`, `t1`… и возвращаются обратно.

    /// По умолчанию — ряды по два; нечётный последний занимает всю ширину.
    public static func automatic(_ ids: [ID]) -> TileLayout? {
        let codec = Codec(ids)
        return tilesAutomatic(ids: ids.map(codec.key)).flatMap(codec.decode)
    }

    /// Новая плитка: дополняет последний неполный ряд или начинает новый снизу.
    public func appending(_ id: ID) -> TileLayout {
        let codec = Codec(ids + [id])
        return tilesAppending(layout: codec.encode(self), id: codec.key(id)).flatMap(codec.decode) ?? self
    }

    public func removing(_ id: ID) -> TileLayout? {
        let codec = Codec(ids + [id])
        return tilesRemoving(layout: codec.encode(self), id: codec.key(id)).flatMap(codec.decode)
    }

    /// Вставить `id` у края плитки `target` (nil — у края всей раскладки, на всю ширину/высоту).
    public func inserting(_ id: ID, at edge: Edge, of target: ID?) -> TileLayout {
        let codec = Codec(ids + [id] + (target.map { [$0] } ?? []))
        return tilesInserting(layout: codec.encode(self), id: codec.key(id), edge: edge.rust, target: target.map(codec.key))
            .flatMap(codec.decode) ?? self
    }

    /// Поменять две плитки местами.
    public func swapping(_ a: ID, _ b: ID) -> TileLayout {
        let codec = Codec(ids + [a, b])
        return tilesSwapping(layout: codec.encode(self), a: codec.key(a), b: codec.key(b)).flatMap(codec.decode) ?? self
    }

    /// Привести к списку открытых: закрытые убрать, новые добавить.
    public func synced(with ids: [ID]) -> TileLayout? {
        let codec = Codec(self.ids + ids)
        return tilesSynced(layout: codec.encode(self), ids: ids.map(codec.key)).flatMap(codec.decode)
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

    /// Соседняя плитка в направлении `edge` от `id` (для ⌥⌘стрелок).
    public func neighbor(of id: ID, toward edge: Edge) -> ID? {
        let codec = Codec(ids + [id])
        return tilesNeighbor(layout: codec.encode(self), id: codec.key(id), edge: edge.rust).flatMap(codec.id)
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

    /// Перевод дерева в JSON ядра (`{"leaf":…}`, `{"row":[…]}`, `{"column":[…]}`) и обратно.
    struct Codec {
        private var keys: [ID: String] = [:]
        private var back: [String: ID] = [:]

        init(_ ids: [ID]) {
            for id in ids where keys[id] == nil {
                let k = "t\(keys.count)"
                keys[id] = k
                back[k] = id
            }
        }

        func key(_ id: ID) -> String { keys[id]! }
        func id(_ key: String) -> ID? { back[key] }

        func encode(_ l: TileLayout) -> String {
            let data = try! JSONSerialization.data(withJSONObject: json(l))
            return String(decoding: data, as: UTF8.self)
        }

        private func json(_ l: TileLayout) -> Any {
            switch l {
            case .leaf(let id): ["leaf": key(id)]
            case .row(let c): ["row": c.map(json)]
            case .column(let c): ["column": c.map(json)]
            }
        }

        func decode(_ s: String) -> TileLayout? {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else { return nil }
            return value(obj)
        }

        private func value(_ obj: Any) -> TileLayout? {
            guard let d = obj as? [String: Any], let (k, v) = d.first else { return nil }
            switch k {
            case "leaf": return (v as? String).flatMap(id).map { .leaf($0) }
            case "row": return (v as? [Any]).map { .row($0.compactMap(value)) }
            case "column": return (v as? [Any]).map { .column($0.compactMap(value)) }
            default: return nil
            }
        }
    }
}

extension TileLayout: Codable where ID: Codable {}

extension TileLayout.Edge {
    var rust: RelayaRust.Edge {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }
}

/// Раскладка по алиасам хостов в общем формате ядра (`{"leaf": "web"}`, `{"row": […]}`, `{"column": […]}`) —
/// так её пишут и читают все клиенты в `layouts.json`.
extension TileLayout where ID == String {
    public var jsonObject: Any {
        switch self {
        case .leaf(let alias): ["leaf": alias]
        case .row(let c): ["row": c.map(\.jsonObject)]
        case .column(let c): ["column": c.map(\.jsonObject)]
        }
    }

    public init?(jsonObject obj: Any) {
        guard let d = obj as? [String: Any], let (k, v) = d.first else { return nil }
        switch k {
        case "leaf": guard let a = v as? String else { return nil }; self = .leaf(a)
        case "row": guard let a = v as? [Any] else { return nil }; self = .row(a.compactMap { TileLayout<String>(jsonObject: $0) })
        case "column": guard let a = v as? [Any] else { return nil }; self = .column(a.compactMap { TileLayout<String>(jsonObject: $0) })
        default: return nil
        }
    }
}

/// Сохранённые раскладки — `layouts.json` в папке данных Relaya, формат общий с Windows и Linux:
/// `[{ "id": "<UUID>", "name": "…", "layout": <раскладка ядра, листья — алиасы> }]`.
public enum LayoutStore {
    public struct Saved: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var layout: TileLayout<String>
        public init(id: UUID = UUID(), name: String, layout: TileLayout<String>) {
            self.id = id
            self.name = name
            self.layout = layout
        }
    }

    public static var url: URL { RelayaPaths.supportDirectory.appending(path: "layouts.json") }

    public static func load() -> [Saved] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let name = d["name"] as? String, let l = d["layout"].flatMap(TileLayout<String>.init(jsonObject:)) else { return nil }
            return Saved(id: (d["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(), name: name, layout: l)
        }
    }

    public static func save(_ list: [Saved]) {
        let json = list.map { ["id": $0.id.uuidString, "name": $0.name, "layout": $0.layout.jsonObject] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
