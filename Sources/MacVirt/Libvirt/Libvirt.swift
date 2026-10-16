// SPDX-License-Identifier: GPL-2.0-or-later
// Thin Swift wrapper around the libvirt C API. All calls are blocking and must
// be made off the main thread (see ConnectionModel).

import CLibvirt
import Foundation

struct LibvirtError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func last(_ fallback: String = "Unknown libvirt error") -> LibvirtError {
        if let msg = virGetLastErrorMessage(), let s = String(validatingCString: msg), s != "no error" {
            return LibvirtError(message: s)
        }
        return LibvirtError(message: fallback)
    }
}

@inline(__always) func check(_ rc: Int32) throws {
    if rc < 0 { throw LibvirtError.last() }
}

/// Converts a malloc'ed C string returned by libvirt to a String and frees it.
func takeString(_ c: UnsafeMutablePointer<CChar>?) throws -> String {
    guard let c else { throw LibvirtError.last() }
    defer { free(c) }
    return String(cString: c)
}

enum Libvirt {
    /// Must be called once before any other libvirt call.
    static func initialize() {
        // The default event loop drives keepalives, domain events and streams
        // (serial consoles). It must be registered before connections open.
        virEventRegisterDefaultImpl()
        let loop = Thread {
            while true { virEventRunDefaultImpl() }
        }
        loop.name = "libvirt-events"
        loop.start()
        virInitialize()
        // Errors are reported through thrown LibvirtError values; keep stderr quiet.
        virSetErrorFunc(nil) { _, _ in }
    }

    static var version: String {
        var v: UInt = 0
        virGetVersion(&v, nil, nil)
        return formatVersion(v)
    }

    static func formatVersion(_ v: UInt) -> String {
        "\(v / 1_000_000).\((v / 1000) % 1000).\(v % 1000)"
    }
}

struct NodeInfo: Sendable {
    var model: String
    var memoryKiB: UInt
    var cpus: Int
    var mhz: Int
    var nodes: Int
    var sockets: Int
    var cores: Int
    var threads: Int
}

final class Connection: @unchecked Sendable {
    let uri: String
    let ptr: virConnectPtr
    private var eventCallbackID: Int32 = -1
    private var eventBox: Unmanaged<CallbackBox>?

    init(uri: String) throws {
        self.uri = uri
        guard let p = virConnectOpen(uri) else { throw LibvirtError.last("Could not connect to \(uri)") }
        ptr = p
        // Detects dead remote connections; needs the event loop.
        virConnectSetKeepAlive(ptr, 5, 3)
    }

    deinit {
        if eventCallbackID >= 0 { virConnectDomainEventDeregisterAny(ptr, eventCallbackID) }
        virConnectClose(ptr)
    }

    var isAlive: Bool { virConnectIsAlive(ptr) == 1 }

    var hostname: String { (try? takeString(virConnectGetHostname(ptr))) ?? "" }

    var hypervisorType: String { virConnectGetType(ptr).map { String(cString: $0) } ?? "" }

    var hypervisorVersion: String {
        var v: UInt = 0
        guard virConnectGetVersion(ptr, &v) == 0 else { return "?" }
        return Libvirt.formatVersion(v)
    }

    var libvirtVersion: String {
        var v: UInt = 0
        guard virConnectGetLibVersion(ptr, &v) == 0 else { return "?" }
        return Libvirt.formatVersion(v)
    }

    func nodeInfo() throws -> NodeInfo {
        var i = virNodeInfo()
        try check(virNodeGetInfo(ptr, &i))
        let model = withUnsafeBytes(of: i.model) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return NodeInfo(model: model, memoryKiB: i.memory, cpus: Int(i.cpus), mhz: Int(i.mhz),
                        nodes: Int(i.nodes), sockets: Int(i.sockets), cores: Int(i.cores), threads: Int(i.threads))
    }

    /// Free host memory in bytes (0 when the driver does not report it).
    var freeMemory: UInt64 { virNodeGetFreeMemory(ptr) }

    func capabilities() throws -> String { try takeString(virConnectGetCapabilities(ptr)) }

    func domainCapabilities(emulator: String?, arch: String?, machine: String?, virttype: String?) throws -> String {
        try takeString(virConnectGetDomainCapabilities(ptr, emulator, arch, machine, virttype, 0))
    }

    /// Calls `handler` (on the libvirt event thread) for every domain lifecycle event.
    func onDomainLifecycle(_ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(CallbackBox(handler))
        typealias LifecycleCB = @convention(c) (virConnectPtr?, virDomainPtr?, Int32, Int32, UnsafeMutableRawPointer?) -> Int32
        let cb: LifecycleCB = { _, _, _, _, opaque in
            guard let opaque else { return 0 }
            Unmanaged<CallbackBox>.fromOpaque(opaque).takeUnretainedValue().handler()
            return 0
        }
        let id = virConnectDomainEventRegisterAny(
            ptr, nil, Int32(VIR_DOMAIN_EVENT_ID_LIFECYCLE.rawValue),
            unsafeBitCast(cb, to: virConnectDomainEventGenericCallback.self),
            box.toOpaque(), { opaque in
                if let opaque { Unmanaged<CallbackBox>.fromOpaque(opaque).release() }
            })
        if id >= 0 { eventCallbackID = id } else { box.release() }
    }

    // MARK: Domains

    func allDomains(flags: UInt32 = 0) throws -> [Domain] {
        var list: UnsafeMutablePointer<virDomainPtr?>?
        let n = virConnectListAllDomains(ptr, &list, flags)
        guard n >= 0, let list else { throw LibvirtError.last() }
        defer { free(list) }
        return (0 ..< Int(n)).compactMap { list[$0].map { Domain(ptr: $0) } }
    }

    func domain(uuid: String) throws -> Domain {
        guard let d = virDomainLookupByUUIDString(ptr, uuid) else { throw LibvirtError.last() }
        return Domain(ptr: d)
    }

    func domain(name: String) throws -> Domain {
        guard let d = virDomainLookupByName(ptr, name) else { throw LibvirtError.last() }
        return Domain(ptr: d)
    }

    @discardableResult
    func defineDomain(xml: String) throws -> Domain {
        guard let d = virDomainDefineXML(ptr, xml) else { throw LibvirtError.last() }
        return Domain(ptr: d)
    }

    // MARK: Node devices

    struct NodeDevice: Sendable, Hashable {
        var name: String
        var xml: String
    }

    func nodeDevices(capability: String) throws -> [NodeDevice] {
        var flags: UInt32 = 0
        switch capability {
        case "usb_device": flags = UInt32(VIR_CONNECT_LIST_NODE_DEVICES_CAP_USB_DEV.rawValue)
        case "pci": flags = UInt32(VIR_CONNECT_LIST_NODE_DEVICES_CAP_PCI_DEV.rawValue)
        default: break
        }
        var list: UnsafeMutablePointer<virNodeDevicePtr?>?
        let n = virConnectListAllNodeDevices(ptr, &list, flags)
        guard n >= 0, let list else { throw LibvirtError.last() }
        defer { free(list) }
        var out: [NodeDevice] = []
        for i in 0 ..< Int(n) {
            guard let d = list[i] else { continue }
            defer { virNodeDeviceFree(d) }
            let name = virNodeDeviceGetName(d).map { String(cString: $0) } ?? ""
            if let xml = try? takeString(virNodeDeviceGetXMLDesc(d, 0)) { out.append(NodeDevice(name: name, xml: xml)) }
        }
        return out
    }
}

final class CallbackBox {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

enum DomainState: Int, Sendable {
    case noState = 0, running, blocked, paused, shutdown, shutoff, crashed, suspended

    var label: String {
        switch self {
        case .noState: "Unknown"
        case .running, .blocked: "Running"
        case .paused: "Paused"
        case .shutdown: "Shutting down"
        case .shutoff: "Shutoff"
        case .crashed: "Crashed"
        case .suspended: "Suspended"
        }
    }

    var isActive: Bool { self != .shutoff && self != .crashed && self != .noState }
}

struct DomainInfo: Sendable {
    var state: DomainState
    var maxMemKiB: UInt
    var memoryKiB: UInt
    var vcpus: Int
    var cpuTimeNs: UInt64
}

final class Domain: @unchecked Sendable {
    let ptr: virDomainPtr

    init(ptr: virDomainPtr) { self.ptr = ptr }
    deinit { virDomainFree(ptr) }

    var name: String { virDomainGetName(ptr).map { String(cString: $0) } ?? "?" }

    var uuid: String {
        var buf = [CChar](repeating: 0, count: Int(VIR_UUID_STRING_BUFLEN))
        virDomainGetUUIDString(ptr, &buf)
        return String(cString: buf)
    }

    var isPersistent: Bool { virDomainIsPersistent(ptr) == 1 }
    var isActive: Bool { virDomainIsActive(ptr) == 1 }

    var autostart: Bool {
        var v: Int32 = 0
        return virDomainGetAutostart(ptr, &v) == 0 && v != 0
    }

    func setAutostart(_ on: Bool) throws { try check(virDomainSetAutostart(ptr, on ? 1 : 0)) }

    var hasManagedSave: Bool { virDomainHasManagedSaveImage(ptr, 0) == 1 }

    func info() throws -> DomainInfo {
        var i = virDomainInfo()
        try check(virDomainGetInfo(ptr, &i))
        return DomainInfo(
            state: DomainState(rawValue: Int(i.state)) ?? .noState,
            maxMemKiB: i.maxMem, memoryKiB: i.memory,
            vcpus: Int(i.nrVirtCpu), cpuTimeNs: i.cpuTime)
    }

    func xml(inactive: Bool = false, secure: Bool = false) throws -> String {
        var flags: UInt32 = 0
        if inactive { flags |= UInt32(VIR_DOMAIN_XML_INACTIVE.rawValue) }
        if secure { flags |= UInt32(VIR_DOMAIN_XML_SECURE.rawValue) }
        return try takeString(virDomainGetXMLDesc(ptr, flags))
    }

    func start() throws { try check(virDomainCreate(ptr)) }
    func shutdown() throws { try check(virDomainShutdown(ptr)) }
    func reboot() throws { try check(virDomainReboot(ptr, 0)) }
    func reset() throws { try check(virDomainReset(ptr, 0)) }
    func forceOff() throws { try check(virDomainDestroy(ptr)) }
    func pause() throws { try check(virDomainSuspend(ptr)) }
    func resume() throws { try check(virDomainResume(ptr)) }
    func managedSave() throws { try check(virDomainManagedSave(ptr, 0)) }
    func removeManagedSave() throws { try check(virDomainManagedSaveRemove(ptr, 0)) }
    func rename(_ newName: String) throws { try check(virDomainRename(ptr, newName, 0)) }

    func undefine() throws {
        let flags = VIR_DOMAIN_UNDEFINE_NVRAM.rawValue
            | VIR_DOMAIN_UNDEFINE_MANAGED_SAVE.rawValue
            | VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA.rawValue
            | VIR_DOMAIN_UNDEFINE_CHECKPOINTS_METADATA.rawValue
        try check(virDomainUndefineFlags(ptr, UInt32(flags)))
    }

    // MARK: Devices

    enum Scope { case config, live, both }

    private func flags(_ scope: Scope) -> UInt32 {
        switch scope {
        case .config: UInt32(VIR_DOMAIN_AFFECT_CONFIG.rawValue)
        case .live: UInt32(VIR_DOMAIN_AFFECT_LIVE.rawValue)
        case .both: UInt32(VIR_DOMAIN_AFFECT_CONFIG.rawValue | VIR_DOMAIN_AFFECT_LIVE.rawValue)
        }
    }

    func attachDevice(_ xml: String, scope: Scope) throws { try check(virDomainAttachDeviceFlags(ptr, xml, flags(scope))) }
    func detachDevice(_ xml: String, scope: Scope) throws { try check(virDomainDetachDeviceFlags(ptr, xml, flags(scope))) }
    func updateDevice(_ xml: String, scope: Scope) throws {
        try check(virDomainUpdateDeviceFlags(ptr, xml, flags(scope)))
    }

    func setVcpus(_ n: Int, live: Bool) throws {
        try check(virDomainSetVcpusFlags(ptr, UInt32(n), UInt32(VIR_DOMAIN_AFFECT_LIVE.rawValue)))
    }

    func setMemory(kib: UInt, live: Bool) throws {
        try check(virDomainSetMemoryFlags(ptr, kib, UInt32(VIR_DOMAIN_AFFECT_LIVE.rawValue)))
    }

    /// Guest OS details reported by the QEMU guest agent (empty without agent).
    func guestInfo() -> [String: String] {
        var params: virTypedParameterPtr?
        var n: Int32 = 0
        let types = VIR_DOMAIN_GUEST_INFO_OS.rawValue | VIR_DOMAIN_GUEST_INFO_HOSTNAME.rawValue
            | VIR_DOMAIN_GUEST_INFO_TIMEZONE.rawValue
        guard virDomainGetGuestInfo(ptr, UInt32(types), &params, &n, 0) == 0 else { return [:] }
        defer { virTypedParamsFree(params, n) }
        let p = TypedParams(params, Int(n))
        var out: [String: String] = [:]
        for key in ["os.pretty-name", "os.name", "os.version", "os.kernel-release", "os.machine", "hostname", "timezone.name"] {
            if let v = p.string(key) { out[key] = v }
        }
        return out
    }

    /// Guest IP addresses from the agent, falling back to DHCP leases.
    func interfaceAddresses() -> [(name: String, mac: String, addrs: [String])] {
        for source in [VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT, VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE] {
            var ifaces: UnsafeMutablePointer<virDomainInterfacePtr?>?
            let n = virDomainInterfaceAddresses(ptr, &ifaces, UInt32(source.rawValue), 0)
            guard n > 0, let ifaces else { continue }
            defer {
                for i in 0 ..< Int(n) { virDomainInterfaceFree(ifaces[i]) }
                free(ifaces)
            }
            var out: [(String, String, [String])] = []
            for i in 0 ..< Int(n) {
                guard let iface = ifaces[i]?.pointee else { continue }
                let name = iface.name.map { String(cString: $0) } ?? ""
                let mac = iface.hwaddr.map { String(cString: $0) } ?? ""
                var addrs: [String] = []
                for a in 0 ..< Int(iface.naddrs) {
                    if let addr = iface.addrs?[a].addr { addrs.append("\(String(cString: addr))/\(iface.addrs![a].prefix)") }
                }
                if name != "lo" { out.append((name, mac, addrs)) }
            }
            return out
        }
        return []
    }

    // MARK: Snapshots

    func snapshots() throws -> [Snapshot] {
        var list: UnsafeMutablePointer<virDomainSnapshotPtr?>?
        let n = virDomainListAllSnapshots(ptr, &list, 0)
        guard n >= 0, let list else { throw LibvirtError.last() }
        defer { free(list) }
        return (0 ..< Int(n)).compactMap { list[$0].map { Snapshot(ptr: $0) } }
    }

    func snapshot(named name: String) throws -> Snapshot {
        guard let s = virDomainSnapshotLookupByName(ptr, name, 0) else { throw LibvirtError.last() }
        return Snapshot(ptr: s)
    }

    @discardableResult
    func createSnapshot(xml: String, flags: UInt32 = 0) throws -> Snapshot {
        guard let s = virDomainSnapshotCreateXML(ptr, xml, flags) else { throw LibvirtError.last() }
        return Snapshot(ptr: s)
    }

    var currentSnapshotName: String? {
        guard virDomainHasCurrentSnapshot(ptr, 0) == 1, let s = virDomainSnapshotCurrent(ptr, 0) else { return nil }
        defer { virDomainSnapshotFree(s) }
        return virDomainSnapshotGetName(s).map { String(cString: $0) }
    }

    // MARK: Console

    /// Opens a text console (serial/console device alias, or nil for the first one).
    func openConsole(device: String?, connection: Connection) throws -> Stream {
        let stream = try Stream(connection: connection)
        try check(virDomainOpenConsole(ptr, device, stream.ptr, UInt32(VIR_DOMAIN_CONSOLE_FORCE.rawValue)))
        return stream
    }

    /// Grabs the guest's screen (PNG or PPM bytes, plus MIME type).
    func screenshot(connection: Connection) throws -> (Data, String) {
        guard let st = virStreamNew(connection.ptr, 0) else { throw LibvirtError.last() }
        defer { virStreamFree(st) }
        guard let mimeC = virDomainScreenshot(ptr, st, 0, 0) else { throw LibvirtError.last() }
        let mime = String(cString: mimeC)
        free(mimeC)
        final class Sink { var data = Data() }
        let sink = Sink()
        let rc = virStreamRecvAll(st, { _, bytes, n, opaque in
            guard let bytes, let opaque else { return -1 }
            Unmanaged<Sink>.fromOpaque(opaque).takeUnretainedValue().data.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: n)
            return Int32(n)
        }, Unmanaged.passUnretained(sink).toOpaque())
        if rc < 0 {
            virStreamAbort(st)
            throw LibvirtError.last()
        }
        virStreamFinish(st)
        return (sink.data, mime)
    }

    // MARK: Migration

    /// Live-migrates to `dest`. `temporary` keeps the definition on the source.
    func migrate(to dest: Connection, tunnelled: Bool, migrationURI: String?, unsafe: Bool, temporary: Bool) throws {
        var f = VIR_MIGRATE_LIVE.rawValue
        if !temporary { f |= VIR_MIGRATE_PERSIST_DEST.rawValue | VIR_MIGRATE_UNDEFINE_SOURCE.rawValue }
        if unsafe { f |= VIR_MIGRATE_UNSAFE.rawValue }
        if tunnelled {
            f |= VIR_MIGRATE_PEER2PEER.rawValue | VIR_MIGRATE_TUNNELLED.rawValue
            try check(virDomainMigrateToURI(ptr, dest.uri, UInt(f), nil, 0))
        } else {
            guard let d = virDomainMigrate(ptr, dest.ptr, UInt(f), nil, migrationURI, 0) else { throw LibvirtError.last() }
            virDomainFree(d)
        }
    }

    func abortJob() { virDomainAbortJob(ptr) }
}

final class Snapshot: @unchecked Sendable {
    let ptr: virDomainSnapshotPtr

    init(ptr: virDomainSnapshotPtr) { self.ptr = ptr }
    deinit { virDomainSnapshotFree(ptr) }

    var name: String { virDomainSnapshotGetName(ptr).map { String(cString: $0) } ?? "?" }
    var isCurrent: Bool { virDomainSnapshotIsCurrent(ptr, 0) == 1 }

    func xml() throws -> String { try takeString(virDomainSnapshotGetXMLDesc(ptr, 0)) }

    func revert(start: Bool, force: Bool) throws {
        var f: UInt32 = 0
        if start { f |= UInt32(VIR_DOMAIN_SNAPSHOT_REVERT_RUNNING.rawValue) }
        if force { f |= UInt32(VIR_DOMAIN_SNAPSHOT_REVERT_FORCE.rawValue) }
        try check(virDomainRevertToSnapshot(ptr, f))
    }

    func delete(children: Bool = false) throws {
        try check(virDomainSnapshotDelete(ptr, children ? UInt32(VIR_DOMAIN_SNAPSHOT_DELETE_CHILDREN.rawValue) : 0))
    }
}

extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
