// SPDX-License-Identifier: GPL-2.0-or-later
// Storage pools, volumes and virtual networks.

import CLibvirt
import Foundation

enum PoolState: Int, Sendable {
    case inactive = 0, building, running, degraded, inaccessible

    var label: String {
        switch self {
        case .inactive: "Inactive"
        case .building: "Building"
        case .running: "Active"
        case .degraded: "Degraded"
        case .inaccessible: "Inaccessible"
        }
    }
}

struct PoolInfo: Sendable, Hashable {
    var state: PoolState
    var capacity: UInt64
    var allocation: UInt64
    var available: UInt64
}

final class StoragePool: @unchecked Sendable {
    let ptr: virStoragePoolPtr
    init(ptr: virStoragePoolPtr) { self.ptr = ptr }
    deinit { virStoragePoolFree(ptr) }

    var name: String { virStoragePoolGetName(ptr).map { String(cString: $0) } ?? "?" }
    var isActive: Bool { virStoragePoolIsActive(ptr) == 1 }
    var isPersistent: Bool { virStoragePoolIsPersistent(ptr) == 1 }

    var autostart: Bool {
        var v: Int32 = 0
        return virStoragePoolGetAutostart(ptr, &v) == 0 && v != 0
    }

    func setAutostart(_ on: Bool) throws { try check(virStoragePoolSetAutostart(ptr, on ? 1 : 0)) }

    func info() throws -> PoolInfo {
        var i = virStoragePoolInfo()
        try check(virStoragePoolGetInfo(ptr, &i))
        return PoolInfo(state: PoolState(rawValue: Int(i.state)) ?? .inactive,
                        capacity: i.capacity, allocation: i.allocation, available: i.available)
    }

    func xml() throws -> String { try takeString(virStoragePoolGetXMLDesc(ptr, 0)) }
    func start() throws { try check(virStoragePoolCreate(ptr, 0)) }
    func stop() throws { try check(virStoragePoolDestroy(ptr)) }
    func build() throws { try check(virStoragePoolBuild(ptr, 0)) }
    func refresh() throws { try check(virStoragePoolRefresh(ptr, 0)) }
    func undefine() throws { try check(virStoragePoolUndefine(ptr)) }
    func deleteUnderlying() throws { try check(virStoragePoolDelete(ptr, 0)) }

    func volumes() throws -> [StorageVolume] {
        var list: UnsafeMutablePointer<virStorageVolPtr?>?
        let n = virStoragePoolListAllVolumes(ptr, &list, 0)
        guard n >= 0, let list else { throw LibvirtError.last() }
        defer { free(list) }
        return (0 ..< Int(n)).compactMap { list[$0].map { StorageVolume(ptr: $0) } }
    }

    func volume(named name: String) throws -> StorageVolume {
        guard let v = virStorageVolLookupByName(ptr, name) else { throw LibvirtError.last() }
        return StorageVolume(ptr: v)
    }

    @discardableResult
    func createVolume(xml: String, cloneFrom: StorageVolume? = nil) throws -> StorageVolume {
        let v: virStorageVolPtr?
        if let src = cloneFrom {
            v = virStorageVolCreateXMLFrom(ptr, xml, src.ptr, 0)
        } else {
            v = virStorageVolCreateXML(ptr, xml, 0)
        }
        guard let v else { throw LibvirtError.last() }
        return StorageVolume(ptr: v)
    }
}

struct VolumeInfo: Sendable, Hashable {
    var type: Int
    var capacity: UInt64
    var allocation: UInt64
}

final class StorageVolume: @unchecked Sendable {
    let ptr: virStorageVolPtr
    init(ptr: virStorageVolPtr) { self.ptr = ptr }
    deinit { virStorageVolFree(ptr) }

    var name: String { virStorageVolGetName(ptr).map { String(cString: $0) } ?? "?" }
    var path: String { (try? takeString(virStorageVolGetPath(ptr))) ?? "" }

    func info() throws -> VolumeInfo {
        var i = virStorageVolInfo()
        try check(virStorageVolGetInfo(ptr, &i))
        return VolumeInfo(type: Int(i.type), capacity: i.capacity, allocation: i.allocation)
    }

    func xml() throws -> String { try takeString(virStorageVolGetXMLDesc(ptr, 0)) }
    func delete() throws { try check(virStorageVolDelete(ptr, 0)) }
    func resize(capacity: UInt64) throws { try check(virStorageVolResize(ptr, capacity, 0)) }
}

final class Network: @unchecked Sendable {
    let ptr: virNetworkPtr
    init(ptr: virNetworkPtr) { self.ptr = ptr }
    deinit { virNetworkFree(ptr) }

    var name: String { virNetworkGetName(ptr).map { String(cString: $0) } ?? "?" }
    var isActive: Bool { virNetworkIsActive(ptr) == 1 }
    var isPersistent: Bool { virNetworkIsPersistent(ptr) == 1 }
    var bridgeName: String { (try? takeString(virNetworkGetBridgeName(ptr))) ?? "" }

    var autostart: Bool {
        var v: Int32 = 0
        return virNetworkGetAutostart(ptr, &v) == 0 && v != 0
    }

    func setAutostart(_ on: Bool) throws { try check(virNetworkSetAutostart(ptr, on ? 1 : 0)) }
    func xml() throws -> String { try takeString(virNetworkGetXMLDesc(ptr, 0)) }
    func start() throws { try check(virNetworkCreate(ptr)) }
    func stop() throws { try check(virNetworkDestroy(ptr)) }
    func undefine() throws { try check(virNetworkUndefine(ptr)) }
}

extension Connection {
    // MARK: Pools

    func storagePools() throws -> [StoragePool] {
        var list: UnsafeMutablePointer<virStoragePoolPtr?>?
        let n = virConnectListAllStoragePools(ptr, &list, 0)
        guard n >= 0, let list else { throw LibvirtError.last() }
        defer { free(list) }
        return (0 ..< Int(n)).compactMap { list[$0].map { StoragePool(ptr: $0) } }
    }

    func storagePool(named name: String) throws -> StoragePool {
        guard let p = virStoragePoolLookupByName(ptr, name) else { throw LibvirtError.last() }
        return StoragePool(ptr: p)
    }

    @discardableResult
    func defineStoragePool(xml: String) throws -> StoragePool {
        guard let p = virStoragePoolDefineXML(ptr, xml, 0) else { throw LibvirtError.last() }
        return StoragePool(ptr: p)
    }

    func storagePoolNames() throws -> [String] {
        try storagePools().filter(\.isActive).map(\.name)
    }

    func volume(path: String) throws -> StorageVolume {
        guard let v = virStorageVolLookupByPath(ptr, path) else { throw LibvirtError.last() }
        return StorageVolume(ptr: v)
    }

    /// Creates a qcow2 volume in the named pool and returns its path on the host.
    func createVolume(pool: String, name: String, capacityGiB: Int) throws -> String {
        let xml = VolumeXML.make(name: name, format: "qcow2", capacityBytes: UInt64(capacityGiB) << 30, allocationBytes: 0)
        return try storagePool(named: pool).createVolume(xml: xml).path
    }

    func deleteVolume(path: String) throws { try volume(path: path).delete() }

    // MARK: Networks

    func networks() throws -> [Network] {
        var list: UnsafeMutablePointer<virNetworkPtr?>?
        let n = virConnectListAllNetworks(ptr, &list, 0)
        guard n >= 0, let list else { throw LibvirtError.last() }
        defer { free(list) }
        return (0 ..< Int(n)).compactMap { list[$0].map { Network(ptr: $0) } }
    }

    func network(named name: String) throws -> Network {
        guard let n = virNetworkLookupByName(ptr, name) else { throw LibvirtError.last() }
        return Network(ptr: n)
    }

    @discardableResult
    func defineNetwork(xml: String) throws -> Network {
        guard let n = virNetworkDefineXML(ptr, xml) else { throw LibvirtError.last() }
        return Network(ptr: n)
    }
}

enum VolumeXML {
    static func make(name: String, format: String, capacityBytes: UInt64, allocationBytes: UInt64,
                     backingPath: String? = nil, backingFormat: String? = nil) -> String {
        var backing = ""
        if let backingPath {
            backing = "<backingStore><path>\(backingPath.xmlEscaped)</path><format type='\(backingFormat ?? "qcow2")'/></backingStore>"
        }
        return """
        <volume>
          <name>\(name.xmlEscaped)</name>
          <capacity unit='bytes'>\(capacityBytes)</capacity>
          <allocation unit='bytes'>\(allocationBytes)</allocation>
          <target><format type='\(format)'/></target>
          \(backing)
        </volume>
        """
    }
}
