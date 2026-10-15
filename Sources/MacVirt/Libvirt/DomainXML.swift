// SPDX-License-Identifier: GPL-2.0-or-later
// Read-only views on libvirt domain and capabilities XML.

import Foundation

struct DomainDetails: Sendable {
    struct Disk: Sendable, Hashable {
        var device: String
        var target: String
        var bus: String
        var source: String
    }

    struct Interface: Sendable, Hashable {
        var type: String
        var mac: String
        var model: String
        var source: String
    }

    struct Graphics: Sendable, Hashable {
        var type: String
        var port: Int
        var listen: String
    }

    var hypervisor = ""
    var arch = ""
    var machine = ""
    var emulator = ""
    var disks: [Disk] = []
    var interfaces: [Interface] = []
    var graphics: [Graphics] = []

    init(xml: String) {
        guard let doc = try? XMLDocument(xmlString: xml) else { return }
        let root = doc.rootElement()
        hypervisor = root?.attr("type") ?? ""
        if let type = doc.first("/domain/os/type") {
            arch = type.attr("arch") ?? ""
            machine = type.attr("machine") ?? ""
        }
        emulator = doc.first("/domain/devices/emulator")?.stringValue ?? ""
        disks = doc.all("/domain/devices/disk").map { d in
            let src = d.first("source")
            return Disk(
                device: d.attr("device") ?? "disk",
                target: d.first("target")?.attr("dev") ?? "",
                bus: d.first("target")?.attr("bus") ?? "",
                source: src?.attr("file") ?? src?.attr("dev") ?? src?.attr("volume") ?? "")
        }
        interfaces = doc.all("/domain/devices/interface").map { i in
            let src = i.first("source")
            return Interface(
                type: i.attr("type") ?? "",
                mac: i.first("mac")?.attr("address") ?? "",
                model: i.first("model")?.attr("type") ?? "",
                source: src?.attr("network") ?? src?.attr("bridge") ?? src?.attr("dev") ?? "")
        }
        graphics = doc.all("/domain/devices/graphics").map { g in
            Graphics(
                type: g.attr("type") ?? "",
                port: Int(g.attr("port") ?? "") ?? -1,
                listen: g.attr("listen") ?? g.first("listen")?.attr("address") ?? "127.0.0.1")
        }
    }
}

/// The parts of `virsh capabilities` the new-VM wizard needs.
struct HostCapabilities: Sendable {
    struct Guest: Sendable, Hashable {
        var arch: String
        var emulator: String
        var domainTypes: [String]
    }

    var hostArch = ""
    var guests: [Guest] = []

    init(xml: String) {
        guard let doc = try? XMLDocument(xmlString: xml) else { return }
        hostArch = doc.first("/capabilities/host/cpu/arch")?.stringValue ?? ""
        var seen = Set<String>()
        for g in doc.all("/capabilities/guest") where g.first("os_type")?.stringValue == "hvm" {
            guard let archEl = g.first("arch"), let arch = archEl.attr("name"), !seen.contains(arch) else { continue }
            seen.insert(arch)
            guests.append(Guest(
                arch: arch,
                emulator: archEl.first("emulator")?.stringValue ?? "",
                domainTypes: archEl.all("domain").compactMap { $0.attr("type") }))
        }
    }

    func guest(arch: String) -> Guest? { guests.first { $0.arch == arch } }
}

extension XMLNode {
    func first(_ xpath: String) -> XMLElement? {
        (try? nodes(forXPath: xpath))?.first as? XMLElement
    }

    func all(_ xpath: String) -> [XMLElement] {
        ((try? nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement }
    }
}

extension XMLElement {
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
}
