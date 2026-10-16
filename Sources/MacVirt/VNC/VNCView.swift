// SPDX-License-Identifier: GPL-2.0-or-later
// AppKit view that renders an RFB framebuffer and forwards keyboard/mouse input.

import AppKit

final class VNCView: NSView {
    var client: RFBClient?
    private(set) var image: CGImage?
    /// Scale the framebuffer to the view (true) or show it 1:1 (false).
    var scaleToFit = true { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var pressedKeys: [UInt16: UInt32] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        guard !scaleToFit, let image else { return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        return NSSize(width: image.width, height: image.height)
    }

    func framebufferChanged() {
        let sizeChanged = image?.width != client?.width || image?.height != client?.height
        image = client?.makeImage()
        if sizeChanged { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    private var imageRect: CGRect {
        guard let image else { return .zero }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = scaleToFit ? min(bounds.width / iw, bounds.height / ih) : 1
        let w = iw * scale, h = ih * scale
        return CGRect(x: max(0, (bounds.width - w) / 2), y: max(0, (bounds.height - h) / 2), width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        guard let image else { return }
        let r = imageRect
        ctx.saveGState()
        // CGContext draws images bottom-up; undo the view's flip for the image.
        ctx.translateBy(x: 0, y: r.maxY + r.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: r)
        ctx.restoreGState()
    }

    // MARK: Mouse

    private func framebufferPoint(_ event: NSEvent) -> (Int, Int) {
        guard let image else { return (0, 0) }
        let p = convert(event.locationInWindow, from: nil)
        let r = imageRect
        let x = (p.x - r.minX) / r.width * CGFloat(image.width)
        let y = (p.y - r.minY) / r.height * CGFloat(image.height)
        return (Int(x), Int(y))
    }

    private func buttons(_ event: NSEvent) -> UInt8 {
        let pressed = NSEvent.pressedMouseButtons
        var mask: UInt8 = 0
        if pressed & 1 != 0 { mask |= 1 }        // left
        if pressed & 4 != 0 { mask |= 2 }        // middle
        if pressed & 2 != 0 { mask |= 4 }        // right
        return mask
    }

    private func pointer(_ event: NSEvent) {
        let (x, y) = framebufferPoint(event)
        client?.sendPointer(x: x, y: y, buttons: buttons(event))
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event) }
    override func mouseUp(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func rightMouseDown(with event: NSEvent) { pointer(event) }
    override func rightMouseUp(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDown(with event: NSEvent) { pointer(event) }
    override func otherMouseUp(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let (x, y) = framebufferPoint(event)
        client?.scroll(x: x, y: y, up: event.scrollingDeltaY > 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { key(event, down: true) }
    override func keyUp(with event: NSEvent) { key(event, down: false) }

    /// Keep Cmd-shortcuts (Cmd-Q, Cmd-W, ...) for the Mac; everything else goes to the guest.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        key(event, down: true)
        return true
    }

    private func key(_ event: NSEvent, down: Bool) {
        let scancode = KeySyms.scancode[event.keyCode]
        let sym = down ? KeySyms.keysym(for: event) : pressedKeys[event.keyCode] ?? KeySyms.keysym(for: event)
        guard let sym = sym ?? (scancode != nil ? 0 : nil) else { return }
        if down { pressedKeys[event.keyCode] = sym } else { pressedKeys[event.keyCode] = nil }
        client?.sendKey(sym, scancode: scancode, down: down)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let (sym, flag) = KeySyms.modifiers[event.keyCode] else { return }
        let down = event.modifierFlags.contains(flag)
        let scancode = KeySyms.scancode[event.keyCode]
        if event.keyCode == 57 {
            // Caps Lock reports state, not press/release: send a full tap.
            client?.sendKey(sym, scancode: scancode, down: true)
            client?.sendKey(sym, scancode: scancode, down: false)
            return
        }
        if down { pressedKeys[event.keyCode] = sym } else { pressedKeys[event.keyCode] = nil }
        client?.sendKey(sym, scancode: scancode, down: down)
    }

    override func resignFirstResponder() -> Bool {
        // Release held keys so the guest does not see them stuck.
        for (code, sym) in pressedKeys { client?.sendKey(sym, scancode: KeySyms.scancode[code], down: false) }
        pressedKeys = [:]
        return true
    }

    /// Presses the keys in order, then releases them in reverse.
    func sendCombo(_ keysyms: [UInt32]) {
        for k in keysyms { client?.sendKey(k, scancode: KeySyms.scancodeForKeysym[k], down: true) }
        for k in keysyms.reversed() { client?.sendKey(k, scancode: KeySyms.scancodeForKeysym[k], down: false) }
    }
}

enum KeySyms {
    static let shiftL: UInt32 = 0xFFE1
    static let controlL: UInt32 = 0xFFE3
    static let altL: UInt32 = 0xFFE9
    static let superL: UInt32 = 0xFFEB
    static let capsLock: UInt32 = 0xFFE5
    static let delete: UInt32 = 0xFFFF
    static let backspace: UInt32 = 0xFF08
    static let escape: UInt32 = 0xFF1B
    static let print: UInt32 = 0xFF61
    static func f(_ n: Int) -> UInt32 { 0xFFBE + UInt32(n - 1) }

    /// The Send Key menu, as in virt-manager.
    static let sendKeyMenu: [(String, [UInt32])] = [
        ("Ctrl+Alt+Backspace", [controlL, altL, backspace]),
        ("Ctrl+Alt+Delete", [controlL, altL, delete]),
        ("Ctrl+Alt+Shift+Escape", [controlL, altL, shiftL, escape]),
    ] + (1 ... 12).map { ("Ctrl+Alt+F\($0)", [controlL, altL, f($0)]) } + [("Print Screen", [print])]

    /// Modifier key codes -> (keysym, flag).
    static let modifiers: [UInt16: (UInt32, NSEvent.ModifierFlags)] = [
        56: (0xFFE1, .shift), 60: (0xFFE2, .shift),
        59: (0xFFE3, .control), 62: (0xFFE4, .control),
        58: (0xFFE9, .option), 61: (0xFFEA, .option),
        55: (0xFFEB, .command), 54: (0xFFEC, .command),
        57: (0xFFE5, .capsLock),
    ]

    /// macOS virtual key codes for non-character keys.
    private static let special: [UInt16: UInt32] = [
        36: 0xFF0D, 76: 0xFF8D,  // Return, keypad Enter
        48: 0xFF09, 51: 0xFF08, 117: 0xFFFF, 53: 0xFF1B,  // Tab, Backspace, Delete, Escape
        123: 0xFF51, 126: 0xFF52, 124: 0xFF53, 125: 0xFF54,  // arrows
        115: 0xFF50, 119: 0xFF57, 116: 0xFF55, 121: 0xFF56, 114: 0xFF63,  // Home End PgUp PgDn Insert(Help)
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3,
        98: 0xFFC4, 100: 0xFFC5, 101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9,  // F1-F12
        105: 0xFF61,  // F13 -> Print
    ]

    /// macOS virtual key code -> QEMU "qnum" (XT scancode, 0x80 | code for E0-prefixed keys).
    static let scancode: [UInt16: UInt32] = [
        0x00: 0x1E, 0x01: 0x1F, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, 0x05: 0x22, 0x06: 0x2C, 0x07: 0x2D,
        0x08: 0x2E, 0x09: 0x2F, 0x0A: 0x56, 0x0B: 0x30, 0x0C: 0x10, 0x0D: 0x11, 0x0E: 0x12, 0x0F: 0x13,
        0x10: 0x15, 0x11: 0x14, 0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x16: 0x07, 0x17: 0x06,
        0x18: 0x0D, 0x19: 0x0A, 0x1A: 0x08, 0x1B: 0x0C, 0x1C: 0x09, 0x1D: 0x0B, 0x1E: 0x1B, 0x1F: 0x18,
        0x20: 0x16, 0x21: 0x1A, 0x22: 0x17, 0x23: 0x19, 0x24: 0x1C, 0x25: 0x26, 0x26: 0x24, 0x27: 0x28,
        0x28: 0x25, 0x29: 0x27, 0x2A: 0x2B, 0x2B: 0x33, 0x2C: 0x35, 0x2D: 0x31, 0x2E: 0x32, 0x2F: 0x34,
        0x30: 0x0F, 0x31: 0x39, 0x32: 0x29, 0x33: 0x0E, 0x35: 0x01,
        0x36: 0xDC, 0x37: 0xDB, 0x38: 0x2A, 0x39: 0x3A, 0x3A: 0x38, 0x3B: 0x1D, 0x3C: 0x36, 0x3D: 0xB8, 0x3E: 0x9D,
        0x41: 0x53, 0x43: 0x37, 0x45: 0x4E, 0x47: 0x45, 0x4B: 0xB5, 0x4C: 0x9C, 0x4E: 0x4A, 0x51: 0x59,
        0x52: 0x52, 0x53: 0x4F, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4B, 0x57: 0x4C, 0x58: 0x4D, 0x59: 0x47,
        0x5B: 0x48, 0x5C: 0x49, 0x5D: 0x7D, 0x5E: 0x73, 0x5F: 0x7E, 0x66: 0x7B, 0x68: 0x70,
        0x60: 0x3F, 0x61: 0x40, 0x62: 0x41, 0x63: 0x3D, 0x64: 0x42, 0x65: 0x43, 0x67: 0x57, 0x69: 0xB7,
        0x6B: 0x46, 0x6D: 0x44, 0x6F: 0x58, 0x72: 0xD2, 0x73: 0xC7, 0x74: 0xC9, 0x75: 0xD3, 0x76: 0x3E,
        0x77: 0xCF, 0x78: 0x3C, 0x79: 0xD1, 0x7A: 0x3B, 0x7B: 0xCB, 0x7C: 0xCD, 0x7D: 0xD0, 0x7E: 0xC8,
    ]

    /// Scancodes for the keysyms used by the Send Key menu.
    static let scancodeForKeysym: [UInt32: UInt32] = {
        var m: [UInt32: UInt32] = [controlL: 0x1D, altL: 0x38, shiftL: 0x2A, delete: 0xD3, backspace: 0x0E,
                                   escape: 0x01, print: 0xB7]
        let fkeys: [UInt32] = [0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58]
        for (i, s) in fkeys.enumerated() { m[f(i + 1)] = s }
        return m
    }()

    static func keysym(for event: NSEvent) -> UInt32? {
        if let s = special[event.keyCode] { return s }
        // Ignore Option so Option-key combos map to the base key for the guest.
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first else { return nil }
        let v = scalar.value
        if v < 0x20 || v == 0x7F { return nil }
        if v <= 0xFF { return v }
        return 0x0100_0000 | v
    }
}
