// SPDX-License-Identifier: GPL-2.0-or-later
// Minimal RFB (VNC) client: protocol 3.3/3.7/3.8, security None and VNC
// authentication, encodings Raw, CopyRect, ZRLE and DesktopSize.

import CLibvirt
import CommonCrypto
import CoreGraphics
import Foundation

protocol RFBClientDelegate: AnyObject {
    func rfbDidConnect(name: String, width: Int, height: Int)
    func rfbFramebufferChanged()
    func rfbDidDisconnect(error: String?)
    /// Called on the client thread; return nil to cancel.
    func rfbNeedsPassword() -> String?
}

final class RFBClient: @unchecked Sendable {
    weak var delegate: RFBClientDelegate?

    private let transport: VNCTransport
    private let writeLock = NSLock()
    private let fbLock = NSLock()
    private var running = true

    private(set) var width = 0
    private(set) var height = 0
    private var framebuffer: [UInt32] = []
    private var zstream = z_stream()
    private var zstreamReady = false
    private var buttonMask: UInt8 = 0
    /// Set once the server acknowledges the QEMU extended key event encoding.
    private(set) var supportsScancodes = false

    init(transport: VNCTransport) {
        self.transport = transport
    }

    func start() {
        let thread = Thread { [self] in
            do {
                try handshake()
                try messageLoop()
            } catch {
                let msg = running ? error.localizedDescription : nil
                DispatchQueue.main.async { self.delegate?.rfbDidDisconnect(error: msg) }
            }
            if zstreamReady { inflateEnd(&zstream) }
        }
        thread.name = "RFB"
        thread.start()
    }

    func stop() {
        running = false
        transport.close()
    }

    // MARK: Framebuffer access (main thread)

    func makeImage() -> CGImage? {
        fbLock.lock()
        defer { fbLock.unlock() }
        guard width > 0, height > 0 else { return nil }
        let data = framebuffer.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Input (any thread)

    /// Sends a key; with a QEMU scancode (qnum) the guest's own keyboard layout applies.
    func sendKey(_ keysym: UInt32, scancode: UInt32? = nil, down: Bool) {
        if supportsScancodes, let scancode {
            send([255, 0] + be16(down ? 1 : 0) + be32(keysym) + be32(scancode))
        } else {
            send([4, down ? 1 : 0, 0, 0] + be32(keysym))
        }
    }

    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        buttonMask = buttons
        let cx = UInt16(clamping: max(0, min(x, width - 1)))
        let cy = UInt16(clamping: max(0, min(y, height - 1)))
        send([5, buttons] + be16(cx) + be16(cy))
    }

    func scroll(x: Int, y: Int, up: Bool) {
        let bit: UInt8 = up ? 0x08 : 0x10
        sendPointer(x: x, y: y, buttons: buttonMask | bit)
        sendPointer(x: x, y: y, buttons: buttonMask & ~bit)
    }

    private func send(_ bytes: [UInt8]) {
        writeLock.lock()
        defer { writeLock.unlock() }
        try? transport.write(bytes)
    }

    // MARK: Handshake

    private func handshake() throws {
        let versionBytes = try transport.readExactly(12)
        guard let version = String(bytes: versionBytes, encoding: .ascii), version.hasPrefix("RFB ") else {
            throw LibvirtError(message: "Not a VNC server")
        }
        let minor = Int(version.dropFirst(8).prefix(3)) ?? 3
        let useMinor = minor >= 8 ? 8 : (minor == 7 ? 7 : 3)
        try transport.write(Array(String(format: "RFB 003.%03d\n", useMinor).utf8))

        var secType: UInt8
        if useMinor == 3 {
            secType = UInt8(clamping: u32(try transport.readExactly(4)))
            if secType == 0 { throw LibvirtError(message: try readReason()) }
        } else {
            let count = Int(try transport.readExactly(1)[0])
            if count == 0 { throw LibvirtError(message: try readReason()) }
            let types = try transport.readExactly(count)
            if types.contains(1) { secType = 1 }
            else if types.contains(2) { secType = 2 }
            else { throw LibvirtError(message: "Unsupported VNC security types \(types)") }
            try transport.write([secType])
        }

        if secType == 2 {
            let challenge = try transport.readExactly(16)
            guard let password = delegate?.rfbNeedsPassword() else { throw LibvirtError(message: "Authentication cancelled") }
            try transport.write(Self.vncAuthResponse(challenge: challenge, password: password))
        }
        if secType == 2 || useMinor == 8 {
            if u32(try transport.readExactly(4)) != 0 {
                throw LibvirtError(message: useMinor == 8 ? try readReason() : "VNC authentication failed")
            }
        }

        try transport.write([1])  // ClientInit: shared
        let header = try transport.readExactly(24)
        let w = Int(u16(Array(header[0 ..< 2]))), h = Int(u16(Array(header[2 ..< 4])))
        let nameLen = Int(u32(Array(header[20 ..< 24])))
        let name = String(decoding: try transport.readExactly(nameLen), as: UTF8.self)
        resize(w, h)

        // SetPixelFormat: 32bpp, depth 24, little endian, true colour, BGRX in memory.
        send([0, 0, 0, 0, 32, 24, 0, 1] + be16(255) + be16(255) + be16(255) + [16, 8, 0, 0, 0, 0])
        // SetEncodings: ZRLE, CopyRect, Raw, DesktopSize, QEMU extended key events.
        let encodings: [Int32] = [16, 1, 0, -223, -258]
        send([2, 0] + be16(UInt16(encodings.count)) + encodings.flatMap { be32(UInt32(bitPattern: $0)) })
        requestUpdate(incremental: false)

        DispatchQueue.main.async { self.delegate?.rfbDidConnect(name: name, width: w, height: h) }
    }

    private func readReason() throws -> String {
        let len = Int(u32(try transport.readExactly(4)))
        return String(decoding: try transport.readExactly(len), as: UTF8.self)
    }

    static func vncAuthResponse(challenge: [UInt8], password: String) -> [UInt8] {
        // VNC uses DES with the bits of each key byte mirrored.
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in Array(password.utf8.prefix(8)).enumerated() {
            var r: UInt8 = 0
            for bit in 0 ..< 8 where b & (1 << bit) != 0 { r |= 0x80 >> bit }
            key[i] = r
        }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                key, 8, nil, challenge, 16, &out, 16, &moved)
        return out
    }

    private func requestUpdate(incremental: Bool) {
        send([3, incremental ? 1 : 0, 0, 0, 0, 0] + be16(UInt16(clamping: width)) + be16(UInt16(clamping: height)))
    }

    private func resize(_ w: Int, _ h: Int) {
        fbLock.lock()
        width = w
        height = h
        framebuffer = [UInt32](repeating: 0xFF00_0000, count: w * h)
        fbLock.unlock()
    }

    // MARK: Messages

    private func messageLoop() throws {
        while running {
            let type = try transport.readExactly(1)[0]
            switch type {
            case 0: try framebufferUpdate()
            case 1:  // SetColourMapEntries
                let hdr = try transport.readExactly(5)
                _ = try transport.readExactly(Int(u16(Array(hdr[3 ..< 5]))) * 6)
            case 2: break  // Bell
            case 3:  // ServerCutText
                let hdr = try transport.readExactly(7)
                _ = try transport.readExactly(Int(u32(Array(hdr[3 ..< 7]))))
            default:
                throw LibvirtError(message: "Unexpected VNC message \(type)")
            }
        }
    }

    private func framebufferUpdate() throws {
        let hdr = try transport.readExactly(3)
        let rects = Int(u16(Array(hdr[1 ..< 3])))
        for _ in 0 ..< rects {
            let r = try transport.readExactly(12)
            let x = Int(u16(Array(r[0 ..< 2]))), y = Int(u16(Array(r[2 ..< 4])))
            let w = Int(u16(Array(r[4 ..< 6]))), h = Int(u16(Array(r[6 ..< 8])))
            let enc = Int32(bitPattern: u32(Array(r[8 ..< 12])))
            switch enc {
            case 0: try rawRect(x, y, w, h)
            case 1: try copyRect(x, y, w, h)
            case 16: try zrleRect(x, y, w, h)
            case -258:
                supportsScancodes = true
            case -223:
                resize(w, h)
                DispatchQueue.main.async { self.delegate?.rfbDidConnect(name: "", width: w, height: h) }
            default:
                throw LibvirtError(message: "Unsupported VNC encoding \(enc)")
            }
        }
        requestUpdate(incremental: true)
        DispatchQueue.main.async { self.delegate?.rfbFramebufferChanged() }
    }

    private func rawRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        let bytes = try transport.readExactly(w * h * 4)
        fbLock.lock()
        defer { fbLock.unlock() }
        bytes.withUnsafeBytes { src in
            let px = src.bindMemory(to: UInt32.self)
            for row in 0 ..< h where y + row < height {
                let dst = (y + row) * width + x
                for col in 0 ..< min(w, width - x) { framebuffer[dst + col] = px[row * w + col] }
            }
        }
    }

    private func copyRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        let s = try transport.readExactly(4)
        let sx = Int(u16(Array(s[0 ..< 2]))), sy = Int(u16(Array(s[2 ..< 4])))
        fbLock.lock()
        defer { fbLock.unlock() }
        guard sx + w <= width, sy + h <= height, x + w <= width, y + h <= height else { return }
        var tmp = [UInt32](repeating: 0, count: w * h)
        for row in 0 ..< h { for col in 0 ..< w { tmp[row * w + col] = framebuffer[(sy + row) * width + sx + col] } }
        for row in 0 ..< h { for col in 0 ..< w { framebuffer[(y + row) * width + x + col] = tmp[row * w + col] } }
    }

    // MARK: ZRLE

    private func zrleRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        let len = Int(u32(try transport.readExactly(4)))
        var compressed = try transport.readExactly(len)
        if !zstreamReady {
            guard inflateInit_(&zstream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw LibvirtError(message: "zlib init failed")
            }
            zstreamReady = true
        }
        var data = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try compressed.withUnsafeMutableBufferPointer { input in
            zstream.next_in = input.baseAddress
            zstream.avail_in = uInt(len)
            repeat {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { out in
                    zstream.next_out = out.baseAddress
                    zstream.avail_out = uInt(out.count)
                    let rc = inflate(&zstream, Z_SYNC_FLUSH)
                    guard rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR else {
                        throw LibvirtError(message: "ZRLE inflate failed (\(rc))")
                    }
                    return out.count - Int(zstream.avail_out)
                }
                data.append(contentsOf: chunk[0 ..< produced])
                if produced == 0 { break }
            } while zstream.avail_in > 0 || zstream.avail_out == 0
        }

        var p = 0
        func byte() throws -> UInt8 {
            guard p < data.count else { throw LibvirtError(message: "ZRLE data truncated") }
            defer { p += 1 }
            return data[p]
        }
        func cpixel() throws -> UInt32 {
            let b = UInt32(try byte()), g = UInt32(try byte()), r = UInt32(try byte())
            return 0xFF00_0000 | (r << 16) | (g << 8) | b
        }

        fbLock.lock()
        defer { fbLock.unlock() }
        func put(_ px: Int, _ py: Int, _ c: UInt32) {
            if px < width, py < height { framebuffer[py * width + px] = c }
        }

        var ty = y
        while ty < y + h {
            let th = min(64, y + h - ty)
            var tx = x
            while tx < x + w {
                let tw = min(64, x + w - tx)
                let sub = Int(try byte())
                switch sub {
                case 0:
                    for j in 0 ..< th { for i in 0 ..< tw { put(tx + i, ty + j, try cpixel()) } }
                case 1:
                    let c = try cpixel()
                    for j in 0 ..< th { for i in 0 ..< tw { put(tx + i, ty + j, c) } }
                case 2 ... 16:
                    let palette = try (0 ..< sub).map { _ in try cpixel() }
                    let bits = sub == 2 ? 1 : (sub <= 4 ? 2 : 4)
                    let mask = (1 << bits) - 1
                    for j in 0 ..< th {
                        var cur = 0, left = 0
                        for i in 0 ..< tw {
                            if left == 0 { cur = Int(try byte()); left = 8 }
                            left -= bits
                            let idx = (cur >> left) & mask
                            guard idx < palette.count else { throw LibvirtError(message: "Bad ZRLE palette index") }
                            put(tx + i, ty + j, palette[idx])
                        }
                    }
                case 128, 130 ... 255:
                    let palette = sub == 128 ? [] : try (0 ..< sub - 128).map { _ in try cpixel() }
                    var i = 0
                    while i < tw * th {
                        var c: UInt32
                        var run = 1
                        if sub == 128 {
                            c = try cpixel()
                            run = try runLength(byte)
                        } else {
                            let idx = Int(try byte())
                            guard idx & 0x7F < palette.count else { throw LibvirtError(message: "Bad ZRLE palette index") }
                            c = palette[idx & 0x7F]
                            if idx & 0x80 != 0 { run = try runLength(byte) }
                        }
                        for _ in 0 ..< run where i < tw * th {
                            put(tx + i % tw, ty + i / tw, c)
                            i += 1
                        }
                    }
                default:
                    throw LibvirtError(message: "Bad ZRLE subencoding \(sub)")
                }
                tx += 64
            }
            ty += 64
        }
    }

    private func runLength(_ byte: () throws -> UInt8) throws -> Int {
        var run = 1
        while true {
            let b = Int(try byte())
            run += b
            if b != 255 { return run }
        }
    }
}

private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
private func u16(_ b: [UInt8]) -> UInt16 { UInt16(b[0]) << 8 | UInt16(b[1]) }
private func u32(_ b: [UInt8]) -> UInt32 { UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) }
