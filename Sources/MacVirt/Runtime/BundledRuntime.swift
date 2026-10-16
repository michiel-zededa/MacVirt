// SPDX-License-Identifier: GPL-2.0-or-later
// Manages the libvirt + QEMU stack shipped inside MacVirt.app.
//
// Layout inside the bundle:
//   Contents/MacOS/{MacVirt,libvirtd,virsh,qemu-system-*,qemu-img}
//   Contents/Frameworks/*.dylib, Frameworks/libvirt/{connection-driver,storage-backend}/*.dylib
//   Contents/share/qemu/...   (QEMU finds this relative to its binary)
//
// All libvirt session state lives under ~/.macvirt: UNIX socket paths are
// limited to 104 bytes, which rules out ~/Library/Application Support.

import Darwin
import Foundation

enum BundledRuntime {
    static let localURI = "qemu:///session"

    static let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".macvirt")
    static var configDir: URL { baseDir.appendingPathComponent("config") }
    static var runDir: URL { baseDir.appendingPathComponent("run") }
    static var logDir: URL { baseDir.appendingPathComponent("cache") }

    /// Stable symlink to the current app's Contents directory. Domain XML refers
    /// to QEMU and firmware through it, so VMs keep working when the app moves.
    static var stableContents: URL { baseDir.appendingPathComponent("app") }

    static var imagesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacVirt/Images")
    }

    static var bundleContents: URL { Bundle.main.bundleURL.appendingPathComponent("Contents") }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: bundleContents.appendingPathComponent("MacOS/libvirtd").path)
    }

    private static var socketPath: String { runDir.appendingPathComponent("libvirt/libvirt-sock").path }

    /// Sets up the process environment. Must run before libvirt is initialised.
    static func prepare() {
        let fm = FileManager.default
        for dir in [configDir, runDir, logDir, configDir.appendingPathComponent("libvirt"), imagesDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        setenv("XDG_CONFIG_HOME", configDir.path, 1)
        setenv("XDG_RUNTIME_DIR", runDir.path, 1)
        setenv("XDG_CACHE_HOME", logDir.path, 1)
        setenv("XDG_DATA_HOME", baseDir.appendingPathComponent("data").path, 1)
        // libvirt's daemon autostart scrubs the environment, so the spawned daemon
        // would not find our driver modules. We start the daemon ourselves instead.
        setenv("LIBVIRT_AUTOSTART", "0", 1)
        unsetenv("LIBVIRT_DEFAULT_URI")

        // ssh (used by qemu+ssh://) asks for passwords and host keys via askpass
        // when it has no terminal and DISPLAY is set.
        if let askpass = Bundle.main.url(forResource: "askpass", withExtension: "sh") {
            setenv("SSH_ASKPASS", askpass.path, 1)
            setenv("SSH_ASKPASS_REQUIRE", "prefer", 1)
            if getenv("DISPLAY") == nil { setenv("DISPLAY", ":0", 1) }
        }

        guard isAvailable else { return }
        setenv("LIBVIRT_DRIVER_DIR", bundleContents.appendingPathComponent("Frameworks/libvirt/connection-driver").path, 1)
        setenv("LIBVIRT_STORAGE_BACKEND_DIR", bundleContents.appendingPathComponent("Frameworks/libvirt/storage-backend").path, 1)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", bundleContents.appendingPathComponent("MacOS").path + ":" + path, 1)

        // virtlogd would be autostarted with a scrubbed environment as well;
        // let QEMU write its logs directly.
        let qemuConf = configDir.appendingPathComponent("libvirt/qemu.conf")
        try? "stdio_handler = \"file\"\n".write(to: qemuConf, atomically: true, encoding: .utf8)
        // One monolithic libvirtd (QEMU + storage drivers) instead of per-driver
        // daemons, so local storage pools work too.
        let clientConf = configDir.appendingPathComponent("libvirt/libvirt.conf")
        try? "remote_mode = \"legacy\"\n".write(to: clientConf, atomically: true, encoding: .utf8)

        try? fm.removeItem(at: stableContents)
        try? fm.createSymbolicLink(at: stableContents, withDestinationURL: bundleContents)
    }

    /// Makes sure a libvirtd from this bundle is listening on the session socket.
    static func ensureDaemon() throws {
        guard isAvailable else {
            throw LibvirtError(message: "The bundled libvirt daemon is missing. Run MacVirt from its .app bundle.")
        }
        if socketAccepts() { return }
        try? FileManager.default.removeItem(atPath: socketPath)

        let daemon = Process()
        daemon.executableURL = bundleContents.appendingPathComponent("MacOS/libvirtd")
        // The daemon will not exit while VMs are running.
        daemon.arguments = ["--timeout=600"]
        let log = logDir.appendingPathComponent("libvirtd.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        daemon.standardOutput = try? FileHandle(forWritingTo: log)
        daemon.standardError = daemon.standardOutput
        try daemon.run()

        for _ in 0 ..< 100 {
            if socketAccepts() { return }
            if !daemon.isRunning {
                throw LibvirtError(message: "libvirtd exited with status \(daemon.terminationStatus); see \(log.path)")
            }
            usleep(100_000)
        }
        throw LibvirtError(message: "Timed out waiting for libvirtd; see \(log.path)")
    }

    private static func socketAccepts() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }

    // MARK: Paths used in generated domain XML

    static func qemuBinary(arch: String) -> String {
        stableContents.appendingPathComponent("MacOS/qemu-system-\(arch)").path
    }

    static func firmware(_ name: String) -> String {
        stableContents.appendingPathComponent("share/qemu/\(name)").path
    }

    /// Defines the "default" storage pool for local VMs (the Images folder).
    static func ensureDefaultPool(_ conn: Connection) {
        if (try? conn.storagePool(named: "default")) != nil { return }
        let xml = "<pool type='dir'><name>default</name><target><path>\(imagesDir.path.xmlEscaped)</path></target></pool>"
        guard let pool = try? conn.defineStoragePool(xml: xml) else { return }
        try? pool.build()
        try? pool.start()
        try? pool.setAutostart(true)
    }

    /// Creates a qcow2 disk image with the bundled qemu-img.
    static func createDiskImage(at url: URL, sizeGiB: Int) throws {
        let p = Process()
        p.executableURL = bundleContents.appendingPathComponent("MacOS/qemu-img")
        p.arguments = ["create", "-q", "-f", "qcow2", url.path, "\(sizeGiB)G"]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LibvirtError(message: "qemu-img failed: \(msg)")
        }
    }
}
