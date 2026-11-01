import AppKit
import Carbon.HIToolbox
import RelayaCore

/// Экран удалённой машины из кадров ядра (BGRA) и ввод: клавиши — scancode набора 1, мышь, колесо.
/// Картинка вписывается в вид с сохранением пропорций; координаты мыши пересчитываются в пиксели сервера.
final class RDPCanvasView: NSView {
    /// Ввод уходит сюда (главный поток).
    var engine: RDPEngine?
    /// Размер вида изменился (точки, масштаб экрана) — для «по размеру окна».
    var onSurfaceChange: ((CGSize, CGFloat) -> Void)?
    /// Вид получил фокус — отправить на сервер локальный буфер обмена.
    var onFocus: (() -> Void)?

    private var pixels = Data()
    private var remote = (width: 0, height: 0)
    private var image: CGImage?
    private var dirty = false
    private var pressed = Set<UInt16>()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Кадры

    /// Новый размер рабочего стола: буфер пересоздаётся, следом ядро пришлёт полный кадр.
    func reset(width: Int, height: Int) {
        remote = (width, height)
        pixels = Data(count: width * height * 4)
        image = nil
        layer?.contents = nil
    }

    func apply(_ rects: [RDPEngine.Rect]) {
        let (w, h) = remote
        guard w > 0, h > 0 else { return }
        pixels.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            for r in rects {
                // Ядро клампит прямоугольники, но границы проверяем и здесь.
                guard r.x >= 0, r.y >= 0, r.width > 0, r.height > 0, r.x + r.width <= w, r.y + r.height <= h,
                      r.bgra.count >= r.width * r.height * 4 else { continue }
                r.bgra.withUnsafeBytes { src in
                    guard let s = src.baseAddress else { return }
                    for row in 0..<r.height {
                        memcpy(base + ((r.y + row) * w + r.x) * 4, s + row * r.width * 4, r.width * 4)
                    }
                }
            }
        }
        // Несколько пачек за цикл главного потока — одна перерисовка.
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.async { [weak self] in self?.present() }
    }

    private func present() {
        dirty = false
        let (w, h) = remote
        guard w > 0, h > 0, let provider = CGDataProvider(data: pixels as CFData) else { return }
        image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onSurfaceChange?(newSize, window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onSurfaceChange?(bounds.size, window?.backingScaleFactor ?? 2)
    }

    // MARK: - Мышь

    /// Точка вида → пиксель сервера с учётом вписывания с полями.
    private func remotePoint(_ event: NSEvent) -> (Int, Int)? {
        let (w, h) = remote
        guard w > 0, h > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / CGFloat(w), bounds.height / CGFloat(h))
        let ox = (bounds.width - CGFloat(w) * scale) / 2, oy = (bounds.height - CGFloat(h) * scale) / 2
        let x = Int(((p.x - ox) / scale).rounded(.down)), y = Int(((p.y - oy) / scale).rounded(.down))
        return (min(max(x, 0), w - 1), min(max(y, 0), h - 1))
    }

    private func move(_ event: NSEvent) {
        if let (x, y) = remotePoint(event) { engine?.pointer(x: x, y: y) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        move(event)
        // Control-клик на Mac — правая кнопка.
        engine?.button(event.modifierFlags.contains(.control) ? 2 : 0, down: true)
    }
    override func mouseUp(with event: NSEvent) {
        move(event)
        engine?.button(event.modifierFlags.contains(.control) ? 2 : 0, down: false)
    }
    override func rightMouseDown(with event: NSEvent) { move(event); engine?.button(2, down: true) }
    override func rightMouseUp(with event: NSEvent) { move(event); engine?.button(2, down: false) }
    override func otherMouseDown(with event: NSEvent) { move(event); engine?.button(Self.otherButton(event), down: true) }
    override func otherMouseUp(with event: NSEvent) { move(event); engine?.button(Self.otherButton(event), down: false) }

    private static func otherButton(_ event: NSEvent) -> Int {
        switch event.buttonNumber { case 3: 3; case 4: 4; default: 1 }
    }

    override func scrollWheel(with event: NSEvent) {
        move(event)
        // Трекпад даёт точные дельты в точках, колесо — строки; приводим к WHEEL_DELTA (120 на щелчок).
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 120
        let dy = Int((event.scrollingDeltaY * k).rounded()), dx = Int((event.scrollingDeltaX * k).rounded())
        if dy != 0 { engine?.wheel(dy, vertical: true) }
        if dx != 0 { engine?.wheel(-dx, vertical: false) }
    }

    // MARK: - Клавиатура

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    /// Отпустить зажатые клавиши: иначе при уходе фокуса сервер считает их нажатыми.
    func releaseAll() {
        for code in pressed { engine?.key(code, down: false) }
        pressed.removeAll()
    }

    // ⌘Q, ⌘W и прочие команды Relaya не перехватываем — остальное уходит на сервер.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command),
           let c = event.charactersIgnoringModifiers?.lowercased(), ["q", "w", "h", "m", "`", ","].contains(c) {
            return false
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if let code = Self.scancodes[Int(event.keyCode)] {
            pressed.insert(code)
            engine?.key(code, down: true)
        } else if let text = event.characters {
            // Клавиши без scancode (редкие раскладки) — символом.
            for s in text.unicodeScalars { engine?.unicode(s.value, down: true); engine?.unicode(s.value, down: false) }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let code = Self.scancodes[Int(event.keyCode)] else { return }
        pressed.remove(code)
        engine?.key(code, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = Self.scancodes[Int(event.keyCode)] else { return }
        let flag: NSEvent.ModifierFlags? = switch Int(event.keyCode) {
        case kVK_Shift, kVK_RightShift: .shift
        case kVK_Control, kVK_RightControl, kVK_Command, kVK_RightCommand: event.keyCode == kVK_Command || event.keyCode == kVK_RightCommand ? .command : .control
        case kVK_Option, kVK_RightOption: .option
        case kVK_CapsLock: .capsLock
        default: nil
        }
        guard let flag else { return }
        if Int(event.keyCode) == kVK_CapsLock {
            // Caps Lock на Mac приходит одним событием на переключение.
            engine?.key(code, down: true); engine?.key(code, down: false)
            return
        }
        let down = event.modifierFlags.contains(flag) && !pressed.contains(code)
        if down { pressed.insert(code) } else { pressed.remove(code) }
        engine?.key(code, down: down)
    }

    /// Отправить сочетание (меню окна): Ctrl+Alt+Del, Win и т.п.
    func send(_ codes: [UInt16]) {
        for c in codes { engine?.key(c, down: true) }
        for c in codes.reversed() { engine?.key(c, down: false) }
    }

    /// Виртуальная клавиша Mac → scancode набора 1 (PC/AT). ⌘ работает как Ctrl: ⌘C/⌘V копируют и вставляют на сервере.
    static let scancodes: [Int: UInt16] = [
        kVK_ANSI_A: 0x1E, kVK_ANSI_S: 0x1F, kVK_ANSI_D: 0x20, kVK_ANSI_F: 0x21, kVK_ANSI_H: 0x23, kVK_ANSI_G: 0x22,
        kVK_ANSI_Z: 0x2C, kVK_ANSI_X: 0x2D, kVK_ANSI_C: 0x2E, kVK_ANSI_V: 0x2F, kVK_ANSI_B: 0x30, kVK_ANSI_Q: 0x10,
        kVK_ANSI_W: 0x11, kVK_ANSI_E: 0x12, kVK_ANSI_R: 0x13, kVK_ANSI_Y: 0x15, kVK_ANSI_T: 0x14, kVK_ANSI_1: 0x02,
        kVK_ANSI_2: 0x03, kVK_ANSI_3: 0x04, kVK_ANSI_4: 0x05, kVK_ANSI_6: 0x07, kVK_ANSI_5: 0x06, kVK_ANSI_Equal: 0x0D,
        kVK_ANSI_9: 0x0A, kVK_ANSI_7: 0x08, kVK_ANSI_Minus: 0x0C, kVK_ANSI_8: 0x09, kVK_ANSI_0: 0x0B,
        kVK_ANSI_RightBracket: 0x1B, kVK_ANSI_O: 0x18, kVK_ANSI_U: 0x16, kVK_ANSI_LeftBracket: 0x1A, kVK_ANSI_I: 0x17,
        kVK_ANSI_P: 0x19, kVK_Return: 0x1C, kVK_ANSI_L: 0x26, kVK_ANSI_J: 0x24, kVK_ANSI_Quote: 0x28, kVK_ANSI_K: 0x25,
        kVK_ANSI_Semicolon: 0x27, kVK_ANSI_Backslash: 0x2B, kVK_ANSI_Comma: 0x33, kVK_ANSI_Slash: 0x35, kVK_ANSI_N: 0x31,
        kVK_ANSI_M: 0x32, kVK_ANSI_Period: 0x34, kVK_Tab: 0x0F, kVK_Space: 0x39, kVK_ANSI_Grave: 0x29, kVK_Delete: 0x0E,
        kVK_Escape: 0x01, kVK_ISO_Section: 0x56,
        kVK_Shift: 0x2A, kVK_RightShift: 0x36, kVK_Control: 0x1D, kVK_RightControl: 0xE01D, kVK_Option: 0x38,
        kVK_RightOption: 0xE038, kVK_Command: 0x1D, kVK_RightCommand: 0xE01D, kVK_CapsLock: 0x3A,
        kVK_F1: 0x3B, kVK_F2: 0x3C, kVK_F3: 0x3D, kVK_F4: 0x3E, kVK_F5: 0x3F, kVK_F6: 0x40, kVK_F7: 0x41, kVK_F8: 0x42,
        kVK_F9: 0x43, kVK_F10: 0x44, kVK_F11: 0x57, kVK_F12: 0x58,
        kVK_Home: 0xE047, kVK_End: 0xE04F, kVK_PageUp: 0xE049, kVK_PageDown: 0xE051, kVK_ForwardDelete: 0xE053,
        kVK_Help: 0xE052, kVK_LeftArrow: 0xE04B, kVK_RightArrow: 0xE04D, kVK_UpArrow: 0xE048, kVK_DownArrow: 0xE050,
        kVK_ANSI_Keypad0: 0x52, kVK_ANSI_Keypad1: 0x4F, kVK_ANSI_Keypad2: 0x50, kVK_ANSI_Keypad3: 0x51,
        kVK_ANSI_Keypad4: 0x4B, kVK_ANSI_Keypad5: 0x4C, kVK_ANSI_Keypad6: 0x4D, kVK_ANSI_Keypad7: 0x47,
        kVK_ANSI_Keypad8: 0x48, kVK_ANSI_Keypad9: 0x49, kVK_ANSI_KeypadDecimal: 0x53, kVK_ANSI_KeypadMultiply: 0x37,
        kVK_ANSI_KeypadPlus: 0x4E, kVK_ANSI_KeypadMinus: 0x4A, kVK_ANSI_KeypadDivide: 0xE035,
        kVK_ANSI_KeypadEnter: 0xE01C, kVK_ANSI_KeypadClear: 0x45,
    ]

    static let ctrlAltDel: [UInt16] = [0x1D, 0x38, 0xE053]
    static let windowsKey: [UInt16] = [0xE05B]
}
