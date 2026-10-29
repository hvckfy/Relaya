// Рисует иконку Relaya во все размеры .iconset.
// Использование: swift scripts/make-icon.swift build/Relaya.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/Relaya.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Плашка в сетке macOS: 824/1024 с отступом.
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.04, green: 0.48, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.02, green: 0.27, blue: 0.62, alpha: 1)])!
        .draw(in: tile, angle: -90)

    // Два узла по диагонали, соединённые через ретранслятор: ● ─ ◆ ─ ●
    let w = rect.width
    let a = NSPoint(x: rect.minX + w * 0.24, y: rect.minY + w * 0.26)
    let c = NSPoint(x: rect.maxX - w * 0.24, y: rect.maxY - w * 0.26)
    let mid = NSPoint(x: rect.midX, y: rect.midY)
    let line = NSBezierPath()
    line.move(to: a)
    line.line(to: c)
    line.lineWidth = w * 0.05
    line.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.6).setStroke()
    line.stroke()

    NSColor.white.setFill()
    for p in [a, c] {
        let r = w * 0.095
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
    }
    let d = w * 0.14
    let diamond = NSBezierPath()
    diamond.move(to: NSPoint(x: mid.x, y: mid.y + d))
    diamond.line(to: NSPoint(x: mid.x + d, y: mid.y))
    diamond.line(to: NSPoint(x: mid.x, y: mid.y - d))
    diamond.line(to: NSPoint(x: mid.x - d, y: mid.y))
    diamond.close()
    NSColor(srgbRed: 1.0, green: 0.72, blue: 0.28, alpha: 1).setFill()
    diamond.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appending(path: "icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appending(path: "icon_\(size)x\(size)@2x.png"))
}
