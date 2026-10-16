// SPDX-License-Identifier: GPL-2.0-or-later
// Bulk domain statistics (one RPC for all domains) via virConnectGetAllDomainStats.

import CLibvirt
import Foundation

struct DomainStatsSample: Sendable {
    var uuid: String
    var name: String
    var state: DomainState
    var cpuTimeNs: UInt64
    var vcpus: Int
    var memoryKiB: UInt64      // balloon.current
    var maxMemoryKiB: UInt64   // balloon.maximum
    var memoryUsedKiB: UInt64? // from rss/unused/available when the guest reports it
    var diskReadBytes: UInt64
    var diskWriteBytes: UInt64
    var netRxBytes: UInt64
    var netTxBytes: UInt64
}

extension Connection {
    func allDomainStats() throws -> [DomainStatsSample] {
        let types = VIR_DOMAIN_STATS_STATE.rawValue | VIR_DOMAIN_STATS_CPU_TOTAL.rawValue
            | VIR_DOMAIN_STATS_BALLOON.rawValue | VIR_DOMAIN_STATS_VCPU.rawValue
            | VIR_DOMAIN_STATS_INTERFACE.rawValue | VIR_DOMAIN_STATS_BLOCK.rawValue
        var records: UnsafeMutablePointer<virDomainStatsRecordPtr?>?
        let n = virConnectGetAllDomainStats(ptr, UInt32(types), &records, 0)
        guard n >= 0, let records else { throw LibvirtError.last() }
        defer { virDomainStatsRecordListFree(records) }

        var out: [DomainStatsSample] = []
        for i in 0 ..< Int(n) {
            guard let rec = records[i]?.pointee, let dom = rec.dom else { continue }
            let p = TypedParams(rec.params, Int(rec.nparams))
            let d = Domain(ptr: dom)
            virDomainRef(dom)  // the record list frees its own reference
            var sample = DomainStatsSample(
                uuid: d.uuid, name: d.name,
                state: DomainState(rawValue: Int(p.int("state.state") ?? 0)) ?? .noState,
                cpuTimeNs: p.uint("cpu.time") ?? 0,
                vcpus: Int(p.uint("vcpu.current") ?? 0),
                memoryKiB: p.uint("balloon.current") ?? 0,
                maxMemoryKiB: p.uint("balloon.maximum") ?? 0,
                memoryUsedKiB: nil,
                diskReadBytes: 0, diskWriteBytes: 0, netRxBytes: 0, netTxBytes: 0)
            if let avail = p.uint("balloon.available"), let unused = p.uint("balloon.unused"), avail >= unused {
                sample.memoryUsedKiB = avail - unused
            } else if let rss = p.uint("balloon.rss") {
                sample.memoryUsedKiB = rss
            }
            for b in 0 ..< Int(p.uint("block.count") ?? 0) {
                sample.diskReadBytes += p.uint("block.\(b).rd.bytes") ?? 0
                sample.diskWriteBytes += p.uint("block.\(b).wr.bytes") ?? 0
            }
            for nIdx in 0 ..< Int(p.uint("net.count") ?? 0) {
                sample.netRxBytes += p.uint("net.\(nIdx).rx.bytes") ?? 0
                sample.netTxBytes += p.uint("net.\(nIdx).tx.bytes") ?? 0
            }
            if sample.maxMemoryKiB == 0 || sample.vcpus == 0, let info = try? d.info() {
                sample.maxMemoryKiB = UInt64(info.maxMemKiB)
                sample.vcpus = info.vcpus
                if sample.memoryKiB == 0 { sample.memoryKiB = UInt64(info.memoryKiB) }
            }
            out.append(sample)
        }
        return out
    }
}

/// Read-only view on a libvirt typed parameter array.
struct TypedParams {
    private var values: [String: virTypedParameter] = [:]

    init(_ params: virTypedParameterPtr?, _ count: Int) {
        guard let params else { return }
        for i in 0 ..< count {
            let p = params[i]
            let field = withUnsafeBytes(of: p.field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            values[field] = p
        }
    }

    func uint(_ key: String) -> UInt64? {
        guard let p = values[key] else { return nil }
        switch Int32(p.type) {
        case Int32(VIR_TYPED_PARAM_INT.rawValue): return UInt64(max(0, p.value.i))
        case Int32(VIR_TYPED_PARAM_UINT.rawValue): return UInt64(p.value.ui)
        case Int32(VIR_TYPED_PARAM_LLONG.rawValue): return UInt64(max(0, p.value.l))
        case Int32(VIR_TYPED_PARAM_ULLONG.rawValue): return p.value.ul
        case Int32(VIR_TYPED_PARAM_DOUBLE.rawValue): return UInt64(max(0, p.value.d))
        case Int32(VIR_TYPED_PARAM_BOOLEAN.rawValue): return p.value.b != 0 ? 1 : 0
        default: return nil
        }
    }

    func int(_ key: String) -> Int64? { uint(key).map { Int64($0) } }

    func string(_ key: String) -> String? {
        guard let p = values[key], Int32(p.type) == Int32(VIR_TYPED_PARAM_STRING.rawValue), let s = p.value.s else { return nil }
        return String(cString: s)
    }
}
