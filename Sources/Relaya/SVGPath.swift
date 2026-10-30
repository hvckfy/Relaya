import SwiftUI

/// Фигура из атрибута `d` SVG (вьюбокс 24×24), масштабируется под рамку.
struct SVGPathShape: Shape {
    let path: Path

    init(_ d: String) { path = SVGPathParser.parse(d) }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: rect.minX + (rect.width - 24 * s) / 2,
                                             y: rect.minY + (rect.height - 24 * s) / 2)))
    }
}

/// Разбор пути SVG: M L H V C S Q T A Z, абсолютные и относительные.
enum SVGPathParser {
    nonisolated(unsafe) private static var cache: [String: Path] = [:]

    static func parse(_ d: String) -> Path {
        if let p = cache[d] { return p }
        var t = Tokenizer(Array(d.utf8))
        var path = Path()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?, lastQuad: CGPoint?
        var cmd: UInt8 = 0
        while let c = t.nextCommand(current: cmd) {
            cmd = c
            let rel = c >= 97
            func pt() -> CGPoint? {
                guard let x = t.number(), let y = t.number() else { return nil }
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            var ctrl: CGPoint?, quad: CGPoint?
            switch c | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = pt() else { break }
                path.move(to: p); cur = p; start = p
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = pt() else { break }
                path.addLine(to: p); cur = p
            case UInt8(ascii: "h"):
                guard let x = t.number() else { break }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case UInt8(ascii: "v"):
                guard let y = t.number() else { break }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case UInt8(ascii: "c"):
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { break }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; ctrl = c2
            case UInt8(ascii: "s"):
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let c2 = pt(), let p = pt() else { break }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; ctrl = c2
            case UInt8(ascii: "q"):
                guard let q = pt(), let p = pt() else { break }
                path.addQuadCurve(to: p, control: q); cur = p; quad = q
            case UInt8(ascii: "t"):
                let q = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let p = pt() else { break }
                path.addQuadCurve(to: p, control: q); cur = p; quad = q
            case UInt8(ascii: "a"):
                guard let rx = t.number(), let ry = t.number(), let rot = t.number(),
                      let large = t.flag(), let sweep = t.flag(), let p = pt() else { break }
                arc(&path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = p
            case UInt8(ascii: "z"):
                path.closeSubpath(); cur = start
            default:
                break
            }
            lastCtrl = ctrl
            lastQuad = quad
        }
        cache[d] = path
        return path
    }

    /// Дуга SVG (endpoint) → кубические кривые.
    private static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: Double, ry: Double,
                            rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ a: Double) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func deriv(_ a: Double) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        var a = theta1
        for _ in 0..<segments {
            let b = a + step
            let pa = point(a), pb = point(b), da = deriv(a), db = deriv(b)
            path.addCurve(to: pb, control1: CGPoint(x: pa.x + k * da.x, y: pa.y + k * da.y),
                          control2: CGPoint(x: pb.x - k * db.x, y: pb.y - k * db.y))
            a = b
        }
    }

    private struct Tokenizer {
        let s: [UInt8]
        var i = 0
        init(_ s: [UInt8]) { self.s = s }

        mutating func skip() {
            while i < s.count, s[i] == 32 || s[i] == 44 || s[i] == 10 || s[i] == 9 || s[i] == 13 { i += 1 }
        }

        /// Следующая команда; если идут числа — повтор предыдущей.
        mutating func nextCommand(current: UInt8) -> UInt8? {
            skip()
            guard i < s.count else { return nil }
            let c = s[i]
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122), c != UInt8(ascii: "e"), c != UInt8(ascii: "E") {
                i += 1
                return c
            }
            return current == 0 ? nil : current
        }

        mutating func flag() -> Bool? {
            skip()
            guard i < s.count, s[i] == 48 || s[i] == 49 else { return nil }
            defer { i += 1 }
            return s[i] == 49
        }

        mutating func number() -> Double? {
            skip()
            let begin = i
            if i < s.count, s[i] == 45 || s[i] == 43 { i += 1 }
            var dot = false, digits = false
            while i < s.count {
                let c = s[i]
                if c >= 48 && c <= 57 { digits = true; i += 1 }
                else if c == 46, !dot { dot = true; i += 1 }
                else if (c == 101 || c == 69), digits {
                    i += 1
                    if i < s.count, s[i] == 45 || s[i] == 43 { i += 1 }
                } else { break }
            }
            guard digits else { i = begin; return nil }
            return Double(String(decoding: s[begin..<i], as: UTF8.self))
        }
    }
}
