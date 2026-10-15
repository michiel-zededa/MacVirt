// SPDX-License-Identifier: GPL-2.0-or-later
// Byte streams to a VNC server: a direct TCP socket, or `ssh -W` for
// qemu+ssh:// hosts where VNC only listens on the remote loopback.

import Darwin
import Foundation

final class VNCTransport: @unchecked Sendable {
    let readFD: Int32
    let writeFD: Int32
    private let onClose: () -> Void
    private var closed = false
    private let lock = NSLock()

    private init(readFD: Int32, writeFD: Int32, onClose: @escaping () -> Void) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.onClose = onClose
    }

    deinit { close() }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        onClose()
    }

    func readExactly(_ count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress! + got, count - got) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw LibvirtError(message: "Console connection closed") }
            got += n
        }
        return buf
    }

    func write(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress! + sent, bytes.count - sent) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw LibvirtError(message: "Console connection closed") }
            sent += n
        }
    }

    // MARK: Factories (blocking; call off the main thread)

    static func tcp(host: String, port: Int) throws -> VNCTransport {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw LibvirtError(message: "Cannot resolve \(host)")
        }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                if connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                    var one: Int32 = 1
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    return VNCTransport(readFD: fd, writeFD: fd) { Darwin.close(fd) }
                }
                Darwin.close(fd)
            }
            ai = a.pointee.ai_next
        }
        throw LibvirtError(message: "Cannot connect to VNC at \(host):\(port)")
    }

    static func ssh(user: String?, host: String, sshPort: Int?, targetHost: String, targetPort: Int) throws -> VNCTransport {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "ServerAliveInterval=30", "-W", "\(targetHost):\(targetPort)"]
        if let sshPort { args += ["-p", String(sshPort)] }
        args.append(user.map { "\($0)@\(host)" } ?? host)
        p.arguments = args
        let toSSH = Pipe(), fromSSH = Pipe()
        p.standardInput = toSSH
        p.standardOutput = fromSSH
        p.standardError = FileHandle.nullDevice
        try p.run()
        return VNCTransport(readFD: fromSSH.fileHandleForReading.fileDescriptor,
                            writeFD: toSSH.fileHandleForWriting.fileDescriptor) {
            if p.isRunning { p.terminate() }
            try? toSSH.fileHandleForWriting.close()
            try? fromSSH.fileHandleForReading.close()
        }
    }

    /// Picks the right transport for a libvirt URI and a VNC listener on that host.
    static func make(libvirtURI: String, graphics: DomainDetails.Graphics) throws -> VNCTransport {
        guard graphics.port > 0 else { throw LibvirtError(message: "The VM has no active VNC display") }
        let comps = URLComponents(string: libvirtURI)
        let scheme = comps?.scheme ?? "qemu"
        let host = comps?.host ?? ""
        var listen = graphics.listen
        if listen.isEmpty || listen == "0.0.0.0" || listen == "::" { listen = "127.0.0.1" }

        if host.isEmpty || host == "localhost" || scheme == "qemu" {
            return try tcp(host: listen, port: graphics.port)
        }
        if scheme.hasSuffix("+ssh") {
            return try ssh(user: comps?.user, host: host, sshPort: comps?.port,
                           targetHost: listen, targetPort: graphics.port)
        }
        // qemu+tcp / qemu+tls: VNC must listen on a reachable address.
        return try tcp(host: listen == "127.0.0.1" ? host : listen, port: graphics.port)
    }
}
