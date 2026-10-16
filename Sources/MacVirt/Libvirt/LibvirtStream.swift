// SPDX-License-Identifier: GPL-2.0-or-later
// Non-blocking libvirt streams (used for serial consoles), driven by the
// default event loop started in Libvirt.initialize().

import CLibvirt
import Foundation

final class Stream: @unchecked Sendable {
    let ptr: virStreamPtr
    private var box: Unmanaged<StreamBox>?
    private let lock = NSLock()
    private var finished = false

    init(connection: Connection) throws {
        guard let s = virStreamNew(connection.ptr, UInt32(VIR_STREAM_NONBLOCK.rawValue)) else { throw LibvirtError.last() }
        ptr = s
    }

    deinit {
        close()
        virStreamFree(ptr)
    }

    /// Delivers received data and end-of-stream on the libvirt event thread.
    func start(onData: @escaping (Data) -> Void, onClose: @escaping (String?) -> Void) {
        let b = Unmanaged.passRetained(StreamBox(stream: self, onData: onData, onClose: onClose))
        box = b
        let events = Int32(VIR_STREAM_EVENT_READABLE.rawValue | VIR_STREAM_EVENT_ERROR.rawValue | VIR_STREAM_EVENT_HANGUP.rawValue)
        let rc = virStreamEventAddCallback(ptr, events, { _, events, opaque in
            guard let opaque else { return }
            Unmanaged<StreamBox>.fromOpaque(opaque).takeUnretainedValue().handle(events: events)
        }, b.toOpaque(), { opaque in
            if let opaque { Unmanaged<StreamBox>.fromOpaque(opaque).release() }
        })
        if rc < 0 {
            b.release()
            box = nil
            onClose(LibvirtError.last().message)
        }
    }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            var off = 0
            while off < buf.count {
                let n = virStreamSend(ptr, base + off, buf.count - off)
                if n == -2 { usleep(1000); continue }  // would block
                if n <= 0 { return }
                off += Int(n)
            }
        }
    }

    func close() {
        lock.lock()
        let wasFinished = finished
        finished = true
        lock.unlock()
        guard !wasFinished else { return }
        // Not under `lock`: the event thread may be waiting for it while holding
        // libvirt's event loop lock, which these calls need too.
        if box != nil { virStreamEventRemoveCallback(ptr) }
        virStreamAbort(ptr)
    }

    fileprivate func receive() -> (Data?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return (nil, true) }
        var buf = [CChar](repeating: 0, count: 16 * 1024)
        let n = virStreamRecv(ptr, &buf, buf.count)
        if n > 0 { return (buf.withUnsafeBytes { Data($0.prefix(Int(n))) }, false) }
        if n == -2 { return (nil, false) }  // nothing yet
        return (nil, true)  // EOF or error
    }
}

private final class StreamBox {
    weak var stream: Stream?
    let onData: (Data) -> Void
    let onClose: (String?) -> Void
    private var closed = false

    init(stream: Stream, onData: @escaping (Data) -> Void, onClose: @escaping (String?) -> Void) {
        self.stream = stream
        self.onData = onData
        self.onClose = onClose
    }

    func handle(events: Int32) {
        guard !closed, let stream else { return }
        if events & Int32(VIR_STREAM_EVENT_READABLE.rawValue) != 0 {
            while true {
                let (data, eof) = stream.receive()
                if let data { onData(data) }
                if eof { return finish(nil) }
                if data == nil { break }
            }
        }
        if events & Int32(VIR_STREAM_EVENT_ERROR.rawValue | VIR_STREAM_EVENT_HANGUP.rawValue) != 0 {
            finish("Console disconnected")
        }
    }

    private func finish(_ message: String?) {
        guard !closed else { return }
        closed = true
        onClose(message)
    }
}
