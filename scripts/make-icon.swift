// SPDX-License-Identifier: GPL-2.0-or-later
// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("MacVirt.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.35, green: 0.20, blue: 0.80, alpha: 1)])!
        .draw(in: path, angle: -60)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let sz = symbol.size
        symbol.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print("wrote \(out.path)")
