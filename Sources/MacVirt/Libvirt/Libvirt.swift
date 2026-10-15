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

enum Libvirt {
    /// Must be called once before any other libvirt call.
    static func initialize() {
        virInitialize()
        // Errors are reported through thrown LibvirtError values; keep stderr quiet.
        virSetErrorFunc(nil) { _, _ in }
    }

    static var version: String {
        var v: UInt = 0
        virGetVersion(&v, nil, nil)
        return "\(v / 1_000_000).\((v / 1000) % 1000).\(v % 1000)"
    }
}

final class Connection: @unchecked Sendable {
    let uri: String
    private let ptr: virConnectPtr

    init(uri: String) throws {
        self.uri = uri
        guard let p = virConnectOpen(uri) else { throw LibvirtError.last("Could not connect to \(uri)") }
        ptr = p
    }

    deinit { virConnectClose(ptr) }

    var isAlive: Bool { virConnectIsAlive(ptr) == 1 }

    var hostname: String {
        guard let c = virConnectGetHostname(ptr) else { return "" }
        defer { free(c) }
        return String(cString: c)
    }

    var hypervisorVersion: String {
        var v: UInt = 0
        guard virConnectGetVersion(ptr, &v) == 0 else { return "?" }
        return "\(v / 1_000_000).\((v / 1000) % 1000).\(v % 1000)"
    }

    func capabilities() throws -> String {
        guard let c = virConnectGetCapabilities(ptr) else { throw LibvirtError.last() }
        defer { free(c) }
        return String(cString: c)
    }

    func domainCapabilities(emulator: String?, arch: String?, machine: String?, virttype: String?) throws -> String {
        guard let c = virConnectGetDomainCapabilities(ptr, emulator, arch, machine, virttype, 0) else {
            throw LibvirtError.last()
        }
        defer { free(c) }
        return String(cString: c)
    }

    func allDomains() throws -> [Domain] {
        var list: UnsafeMutablePointer<virDomainPtr?>?
        let n = virConnectListAllDomains(ptr, &list, 0)
        guard n >= 0, let list else { throw LibvirtError.last() }
        defer { free(list) }
        return (0 ..< Int(n)).compactMap { list[$0].map { Domain(ptr: $0) } }
    }

    func domain(uuid: String) throws -> Domain {
        guard let d = virDomainLookupByUUIDString(ptr, uuid) else { throw LibvirtError.last() }
        return Domain(ptr: d)
    }

    func defineDomain(xml: String) throws -> Domain {
        guard let d = virDomainDefineXML(ptr, xml) else { throw LibvirtError.last() }
        return Domain(ptr: d)
    }

    // MARK: Storage (remote hosts)

    func storagePoolNames() throws -> [String] {
        var list: UnsafeMutablePointer<virStoragePoolPtr?>?
        let n = virConnectListAllStoragePools(ptr, &list, UInt32(VIR_CONNECT_LIST_STORAGE_POOLS_ACTIVE.rawValue))
        guard n >= 0, let list else { throw LibvirtError.last() }
        defer { free(list) }
        var names: [String] = []
        for i in 0 ..< Int(n) {
            guard let p = list[i] else { continue }
            if let c = virStoragePoolGetName(p) { names.append(String(cString: c)) }
            virStoragePoolFree(p)
        }
        return names
    }

    /// Creates a qcow2 volume in the named pool and returns its path on the host.
    func createVolume(pool: String, name: String, capacityGiB: Int) throws -> String {
        guard let p = virStoragePoolLookupByName(ptr, pool) else { throw LibvirtError.last() }
        defer { virStoragePoolFree(p) }
        let xml = """
        <volume><name>\(name.xmlEscaped)</name>
        <capacity unit='GiB'>\(capacityGiB)</capacity>
        <target><format type='qcow2'/></target></volume>
        """
        guard let v = virStorageVolCreateXML(p, xml, 0) else { throw LibvirtError.last() }
        defer { virStorageVolFree(v) }
        guard let path = virStorageVolGetPath(v) else { throw LibvirtError.last() }
        defer { free(path) }
        return String(cString: path)
    }

    func deleteVolume(path: String) throws {
        guard let v = virStorageVolLookupByPath(ptr, path) else { throw LibvirtError.last() }
        defer { virStorageVolFree(v) }
        guard virStorageVolDelete(v, 0) == 0 else { throw LibvirtError.last() }
    }
}

enum DomainState: Int, Sendable {
    case noState = 0, running, blocked, paused, shutdown, shutoff, crashed, suspended

    var label: String {
        switch self {
        case .noState: "Unknown"
        case .running, .blocked: "Running"
        case .paused: "Paused"
        case .shutdown: "Shutting down"
        case .shutoff: "Shut off"
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
    private let ptr: virDomainPtr

    fileprivate init(ptr: virDomainPtr) { self.ptr = ptr }
    deinit { virDomainFree(ptr) }

    var name: String { virDomainGetName(ptr).map { String(cString: $0) } ?? "?" }

    var uuid: String {
        var buf = [CChar](repeating: 0, count: Int(VIR_UUID_STRING_BUFLEN))
        virDomainGetUUIDString(ptr, &buf)
        return String(cString: buf)
    }

    var isPersistent: Bool { virDomainIsPersistent(ptr) == 1 }

    func info() throws -> DomainInfo {
        var i = virDomainInfo()
        guard virDomainGetInfo(ptr, &i) == 0 else { throw LibvirtError.last() }
        return DomainInfo(
            state: DomainState(rawValue: Int(i.state)) ?? .noState,
            maxMemKiB: i.maxMem, memoryKiB: i.memory,
            vcpus: Int(i.nrVirtCpu), cpuTimeNs: i.cpuTime)
    }

    func xml(inactive: Bool = false) throws -> String {
        let flags = inactive ? UInt32(VIR_DOMAIN_XML_INACTIVE.rawValue) : 0
        guard let c = virDomainGetXMLDesc(ptr, flags) else { throw LibvirtError.last() }
        defer { free(c) }
        return String(cString: c)
    }

    private func check(_ rc: Int32) throws { if rc < 0 { throw LibvirtError.last() } }

    func start() throws { try check(virDomainCreate(ptr)) }
    func shutdown() throws { try check(virDomainShutdown(ptr)) }
    func reboot() throws { try check(virDomainReboot(ptr, 0)) }
    func forceOff() throws { try check(virDomainDestroy(ptr)) }
    func pause() throws { try check(virDomainSuspend(ptr)) }
    func resume() throws { try check(virDomainResume(ptr)) }

    func undefine() throws {
        let flags = VIR_DOMAIN_UNDEFINE_NVRAM.rawValue
            | VIR_DOMAIN_UNDEFINE_MANAGED_SAVE.rawValue
            | VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA.rawValue
        try check(virDomainUndefineFlags(ptr, UInt32(flags)))
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
