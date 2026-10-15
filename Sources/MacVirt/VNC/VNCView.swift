// SPDX-License-Identifier: GPL-2.0-or-later
// AppKit view that renders an RFB framebuffer and forwards keyboard/mouse input.

import AppKit

final class VNCView: NSView {
    var client: RFBClient?
    private var image: CGImage?
    private var heldModifiers: Set<UInt32> = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func framebufferChanged() {
        image = client?.makeImage()
        needsDisplay = true
    }

    private var imageRect: CGRect {
        guard let image else { return .zero }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = min(bounds.width / iw, bounds.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
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
        // Control-click acts as right click, as elsewhere on macOS.
        if mask == 1, event.modifierFlags.contains(.control) { mask = 4 }
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
        guard window?.firstResponder === self else { return false }
        key(event, down: event.type == .keyDown)
        return true
    }

    private func key(_ event: NSEvent, down: Bool) {
        guard let sym = KeySyms.keysym(for: event) else { return }
        client?.sendKey(sym, down: down)
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let wanted: [(NSEvent.ModifierFlags, UInt32)] = [
            (.shift, KeySyms.shiftL), (.control, KeySyms.controlL), (.option, KeySyms.altL), (.command, KeySyms.superL),
        ]
        for (flag, sym) in wanted {
            let isDown = flags.contains(flag)
            if isDown != heldModifiers.contains(sym) {
                client?.sendKey(sym, down: isDown)
                if isDown { heldModifiers.insert(sym) } else { heldModifiers.remove(sym) }
            }
        }
        if flags.contains(.capsLock) != heldModifiers.contains(KeySyms.capsLock) {
            client?.sendKey(KeySyms.capsLock, down: true)
            client?.sendKey(KeySyms.capsLock, down: false)
            if flags.contains(.capsLock) { heldModifiers.insert(KeySyms.capsLock) } else { heldModifiers.remove(KeySyms.capsLock) }
        }
    }

    override func resignFirstResponder() -> Bool {
        // Release modifiers so the guest does not see them stuck.
        for sym in heldModifiers where sym != KeySyms.capsLock { client?.sendKey(sym, down: false) }
        heldModifiers = heldModifiers.intersection([KeySyms.capsLock])
        return true
    }

    func sendCtrlAltDel() {
        let seq = [KeySyms.controlL, KeySyms.altL, KeySyms.delete]
        seq.forEach { client?.sendKey($0, down: true) }
        seq.reversed().forEach { client?.sendKey($0, down: false) }
    }
}

enum KeySyms {
    static let shiftL: UInt32 = 0xFFE1
    static let controlL: UInt32 = 0xFFE3
    static let altL: UInt32 = 0xFFE9
    static let superL: UInt32 = 0xFFEB
    static let capsLock: UInt32 = 0xFFE5
    static let delete: UInt32 = 0xFFFF

    /// macOS virtual key codes for non-character keys.
    private static let special: [UInt16: UInt32] = [
        36: 0xFF0D, 76: 0xFF8D,  // Return, keypad Enter
        48: 0xFF09, 51: 0xFF08, 117: 0xFFFF, 53: 0xFF1B,  // Tab, Backspace, Delete, Escape
        123: 0xFF51, 126: 0xFF52, 124: 0xFF53, 125: 0xFF54,  // arrows
        115: 0xFF50, 119: 0xFF57, 116: 0xFF55, 121: 0xFF56, 114: 0xFF63,  // Home End PgUp PgDn Insert(Help)
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3,
        98: 0xFFC4, 100: 0xFFC5, 101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9,  // F1-F12
    ]

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
