// SPDX-License-Identifier: GPL-2.0-or-later
// Editable view on a domain's persistent XML. Detail pages bind to attributes
// and elements of `doc`; Apply redefines the domain from it.

import Foundation
import Observation
import SwiftUI

enum HardwareKind: Int, Comparable {
    case overview, osInfo, performance, cpus, memory, boot
    case disk, nic, input, graphics, sound, char, hostdev, redirdev, video, watchdog
    case controller, filesystem, smartcard, tpm, rng, panic, vsock

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct HardwareItem: Identifiable, Hashable {
    var id: String
    var kind: HardwareKind
    var label: String
    var icon: String
    /// The device element (nil for the VM-level pages).
    var element: XMLElement?

    var isDevice: Bool { element != nil }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.label == b.label }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor @Observable
final class DomainEditor {
    let connection: ConnectionModel
    let uuid: String

    private(set) var doc: XMLDocument?
    private(set) var originalXML = ""
    private(set) var liveXML = ""
    private(set) var revision = 0
    private(set) var isDirty = false
    private(set) var loadError: String?
    var autostart = false
    private(set) var originalAutostart = false
    var applyMessage: String?
    var busy = false

    /// Elements whose live state should be updated on Apply (CD-ROM media, NIC link).
    @ObservationIgnored private var hotUpdates: Set<ObjectIdentifier> = []

    init(connection: ConnectionModel, uuid: String) {
        self.connection = connection
        self.uuid = uuid
    }

    var root: XMLElement? { doc?.rootElement() }
    var devices: XMLElement? { root?.child("devices") }
    var isRunning: Bool { connection.domain(uuid)?.state.isActive ?? false }
    var name: String { root?.child("name")?.stringValue ?? "" }

    // MARK: Loading / applying

    func load() async {
        let uuid = self.uuid
        do {
            let (inactive, live, auto) = try await connection.withConnection { conn in
                let d = try conn.domain(uuid: uuid)
                let inactive = d.isPersistent ? try d.xml(inactive: true, secure: true) : try d.xml(secure: true)
                return (inactive, (try? d.xml()) ?? inactive, d.autostart)
            }
            originalXML = inactive
            liveXML = live
            doc = try XMLDocument(xmlString: inactive, options: [.nodePreserveWhitespace])
            autostart = auto
            originalAutostart = auto
            isDirty = false
            hotUpdates = []
            loadError = nil
            revision += 1
        } catch {
            loadError = error.localizedDescription
        }
    }

    var xmlString: String { doc?.xmlString(options: [.nodePrettyPrint]) ?? originalXML }

    /// Turns this editor into a scratch pad for one new device (Add Hardware).
    func setScratch(_ element: XMLElement) {
        let root = XMLElement(name: "domain")
        let devices = XMLElement(name: "devices")
        devices.addChild(element)
        root.addChild(devices)
        doc = XMLDocument(rootElement: root)
        revision += 1
    }

    func revert() async { await load() }

    func apply() async {
        guard let doc else { return }
        busy = true
        defer { busy = false }
        let xml = doc.xmlString
        let auto = autostart, autoChanged = autostart != originalAutostart
        let running = isRunning
        let hot = devices?.childElements.filter { hotUpdates.contains(ObjectIdentifier($0)) }.map(\.xmlString) ?? []
        let origName = (try? XMLDocument(xmlString: originalXML))?.rootElement()?.child("name")?.stringValue ?? name
        let newName = name
        let uuid = self.uuid
        do {
            var notes: [String] = []
            try await connection.withConnection { conn in
                let d = try conn.domain(uuid: uuid)
                if newName != origName {
                    guard !d.isActive else { throw LibvirtError(message: "A running VM cannot be renamed.") }
                    try d.rename(newName)
                }
                try conn.defineDomain(xml: xml)
                if autoChanged { try d.setAutostart(auto) }
                if running {
                    for dev in hot { try? d.updateDevice(dev, scope: .live) }
                }
            }
            if running && xml != originalXML {
                notes.append("Some changes will take effect after the next guest shutdown.")
            }
            applyMessage = notes.first
            connection.refresh()
            await load()
        } catch {
            applyMessage = nil
            loadError = error.localizedDescription
            connection.lastError = error.localizedDescription
        }
    }

    /// Marks the document changed after a direct edit.
    func touch(_ element: XMLElement? = nil, hot: Bool = false) {
        if hot, let element { hotUpdates.insert(ObjectIdentifier(element)) }
        isDirty = true
        revision += 1
    }

    // MARK: Bindings

    func attr(_ el: XMLElement?, _ name: String, default def: String = "", hot: Bool = false) -> Binding<String> {
        Binding(
            get: { _ = self.revision; return el?.attr(name) ?? def },
            set: { v in
                guard let el else { return }
                if v.isEmpty { el.removeAttribute(forName: name) } else { el.setAttr(name, v) }
                self.touch(el, hot: hot)
            })
    }

    func text(_ el: XMLElement?, _ child: String, default def: String = "") -> Binding<String> {
        Binding(
            get: { _ = self.revision; return el?.child(child)?.stringValue ?? def },
            set: { v in
                guard let el else { return }
                if v.isEmpty { el.child(child).map { el.removeChild(at: $0.index) } }
                else { el.ensure(child).stringValue = v }
                self.touch(el)
            })
    }

    /// Presence of a child element as a toggle.
    func flag(_ el: XMLElement?, _ child: String) -> Binding<Bool> {
        Binding(
            get: { _ = self.revision; return el?.child(child) != nil },
            set: { on in
                guard let el else { return }
                if on { _ = el.ensure(child) } else if let c = el.child(child) { el.removeChild(at: c.index) }
                self.touch(el)
            })
    }

    func number(_ binding: Binding<String>, default def: Int) -> Binding<Int> {
        Binding(get: { Int(binding.wrappedValue) ?? def }, set: { binding.wrappedValue = String($0) })
    }

    /// Replaces a device element with new XML (from a page's XML tab).
    func replace(_ el: XMLElement, withXML xml: String) throws {
        let newEl = try XMLElement(xmlString: xml)
        guard let parent = el.parent as? XMLElement else { return }
        parent.replaceChild(at: el.index, with: newEl)
        touch(newEl)
    }

    // MARK: Hardware list

    var hardwareItems: [HardwareItem] {
        _ = revision
        var items: [HardwareItem] = [
            HardwareItem(id: "overview", kind: .overview, label: "Overview", icon: "info.circle"),
            HardwareItem(id: "osinfo", kind: .osInfo, label: "OS information", icon: "desktopcomputer"),
            HardwareItem(id: "performance", kind: .performance, label: "Performance", icon: "chart.xyaxis.line"),
            HardwareItem(id: "cpus", kind: .cpus, label: "CPUs", icon: "cpu"),
            HardwareItem(id: "memory", kind: .memory, label: "Memory", icon: "memorychip"),
            HardwareItem(id: "boot", kind: .boot, label: "Boot Options", icon: "gearshape.2"),
        ]
        guard let devices else { return items }
        var diskIndex: [String: Int] = [:]
        var devItems: [HardwareItem] = []
        let consoles = devices.elements(forName: "console")
        let serials = devices.elements(forName: "serial")
        for (i, el) in devices.childElements.enumerated() {
            let id = "dev-\(i)-\(el.name ?? "")"
            func add(_ kind: HardwareKind, _ label: String, _ icon: String) {
                devItems.append(HardwareItem(id: id, kind: kind, label: label, icon: icon, element: el))
            }
            switch el.name {
            case "disk":
                let device = el.attr("device") ?? "disk"
                let bus = el.child("target")?.attr("bus") ?? ""
                let key = device == "floppy" ? "fdc" : bus
                diskIndex[key, default: 0] += 1
                let n = diskIndex[key]!
                switch device {
                case "floppy": add(.disk, "Floppy \(n)", "opticaldiscdrive")
                case "cdrom": add(.disk, "\(Pretty.bus(bus)) CDROM \(n)", "opticaldisc")
                case "disk": add(.disk, "\(Pretty.bus(bus)) Disk \(n)", "internaldrive")
                default: add(.disk, "\(Pretty.bus(bus)) \(device.capitalized) \(n)", "internaldrive")
                }
            case "interface":
                let mac = el.child("mac")?.attr("address") ?? ""
                add(.nic, "NIC \(mac.suffix(9))", "network")
            case "input":
                switch el.attr("type") {
                case "tablet": add(.input, "Tablet", "hand.point.up.left")
                case "mouse": add(.input, "Mouse", "computermouse")
                case "keyboard": add(.input, "Keyboard", "keyboard")
                default: add(.input, "Input", "keyboard")
                }
            case "graphics": add(.graphics, "Display \(Pretty.graphics(el.attr("type") ?? ""))", "display")
            case "sound": add(.sound, "Sound \(el.attr("model") ?? "")", "speaker.wave.2")
            case "serial":
                add(.char, "Serial \((Int(el.child("target")?.attr("port") ?? "") ?? 0) + 1)", "cable.connector")
            case "parallel":
                add(.char, "Parallel \((Int(el.child("target")?.attr("port") ?? "") ?? 0) + 1)", "cable.connector")
            case "console":
                // The first console usually duplicates the first serial port.
                if el === consoles.first, !serials.isEmpty, el.attr("type") == "pty",
                   (el.child("target")?.attr("type") ?? "serial") == "serial" { continue }
                add(.char, "Console \((Int(el.child("target")?.attr("port") ?? "") ?? 0) + 1)", "terminal")
            case "channel":
                let type = el.attr("type") ?? ""
                if let name = Pretty.channelName(el.child("target")?.attr("name")), type != "qemu-vdagent" {
                    add(.char, "Channel (\(name))", "cable.connector.horizontal")
                } else {
                    add(.char, "Channel \(Pretty.charType(type))", "cable.connector.horizontal")
                }
            case "hostdev": add(.hostdev, Pretty.hostdev(el), "cable.connector")
            case "redirdev":
                let idx = devices.elements(forName: "redirdev").firstIndex { $0 === el } ?? 0
                add(.redirdev, "\(Pretty.bus(el.attr("bus") ?? "usb")) Redirector \(idx + 1)", "arrow.left.arrow.right")
            case "video": add(.video, "Video \(Pretty.video(el.child("model")?.attr("type") ?? ""))", "rectangle.on.rectangle")
            case "watchdog": add(.watchdog, "Watchdog", "timer")
            case "controller":
                let model = el.attr("model") ?? ""
                if ["ich9-uhci1", "ich9-uhci2", "ich9-uhci3", "pcie-root-port", "dmi-to-pci-bridge", "pci-bridge"].contains(model) { continue }
                let idx = el.attr("index").map { " \($0)" } ?? ""
                add(.controller, "Controller \(Pretty.controller(el))\(idx)", "square.stack.3d.up")
            case "filesystem":
                add(.filesystem, "Filesystem \((el.child("target")?.attr("dir") ?? "").prefix(8))", "folder")
            case "smartcard": add(.smartcard, "Smartcard", "creditcard")
            case "tpm":
                if let path = el.child("backend")?.child("device")?.attr("path") {
                    add(.tpm, "TPM \(path)", "lock.shield")
                } else if let v = el.child("backend")?.attr("version") {
                    add(.tpm, "TPM v\(v)", "lock.shield")
                } else { add(.tpm, "TPM", "lock.shield") }
            case "rng":
                if let dev = el.child("backend")?.stringValue, !dev.isEmpty, el.child("backend")?.attr("model") == "random" {
                    add(.rng, "RNG \(dev)", "dice")
                } else { add(.rng, "RNG", "dice") }
            case "panic": add(.panic, "Panic Notifier", "exclamationmark.triangle")
            case "vsock": add(.vsock, "VirtIO VSOCK", "point.3.connected.trianglepath.dotted")
            default: continue
            }
        }
        // Stable sort by category, keeping XML order within a category.
        items += devItems.enumerated().sorted { a, b in
            a.element.kind == b.element.kind ? a.offset < b.offset : a.element.kind < b.element.kind
        }.map(\.element)
        return items
    }
}

enum Pretty {
    static func bus(_ bus: String) -> String {
        ["ide": "IDE", "nvme": "NVMe", "sata": "SATA", "scsi": "SCSI", "sd": "SD", "usb": "USB",
         "virtio": "VirtIO", "xen": "Xen", "fdc": "Floppy"][bus] ?? bus
    }

    static func graphics(_ type: String) -> String {
        ["vnc": "VNC", "spice": "Spice", "sdl": "SDL", "rdp": "RDP", "dbus": "DBus", "egl-headless": "EGL"][type] ?? type.capitalized
    }

    static func video(_ model: String) -> String {
        ["qxl", "vmvga", "vga"].contains(model) ? model.uppercased() : model.capitalized
    }

    static func channelName(_ name: String?) -> String? {
        guard let name else { return nil }
        return ["com.redhat.spice.0": "spice", "org.qemu.guest_agent.0": "qemu-ga",
                "org.libguestfs.channel.0": "libguestfs", "org.spice-space.webdav.0": "spice-webdav"][name] ?? name
    }

    static func charType(_ type: String) -> String {
        ["pty": "Pseudo TTY", "file": "Output to a file", "tcp": "TCP net console", "udp": "UDP net console",
         "unix": "UNIX socket", "spicevmc": "Spice agent", "spiceport": "Spice port", "qemu-vdagent": "QEMU vdagent",
         "dev": "Physical host device", "pipe": "Named pipe", "stdio": "Standard I/O", "null": "Null device"][type] ?? type
    }

    static func controllerType(_ type: String) -> String {
        ["ide": "IDE", "fdc": "Floppy", "scsi": "SCSI", "sata": "SATA", "virtio-serial": "VirtIO Serial",
         "usb": "USB", "pci": "PCI", "ccid": "CCID", "xenbus": "xenbus", "nvme": "NVMe", "isa": "ISA"][type] ?? type
    }

    static func controller(_ el: XMLElement) -> String {
        let type = el.attr("type") ?? "", model = el.attr("model") ?? ""
        if type == "scsi", model == "virtio-scsi" { return "VirtIO SCSI" }
        if type == "pci", model == "pcie-root" { return "PCIe" }
        return controllerType(type)
    }

    static func hostdev(_ el: XMLElement) -> String {
        let type = (el.attr("type") ?? "").uppercased()
        let src = el.child("source")
        func dehex(_ s: String) -> String { s.hasPrefix("0x") ? String(s.dropFirst(2)) : s }
        if let v = src?.child("vendor")?.attr("id"), let p = src?.child("product")?.attr("id") {
            return "\(type) \(dehex(v)):\(dehex(p))"
        }
        if let a = src?.child("address") {
            if let bus = a.attr("bus"), let dev = a.attr("device") {
                return "\(type) \(String(format: "%03d", Int(bus) ?? 0)):\(String(format: "%03d", Int(dev) ?? 0))"
            }
            if let bus = a.attr("bus"), let slot = a.attr("slot"), let fn = a.attr("function"), let dom = a.attr("domain") {
                return "\(type) \(dehex(dom)):\(dehex(bus)):\(dehex(slot)).\(dehex(fn))"
            }
        }
        return type
    }

    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .binary)
    }

    static func gib(_ b: UInt64) -> String { String(format: "%.2f GiB", Double(b) / 1_073_741_824) }
}

extension XMLElement {
    func child(_ name: String) -> XMLElement? { elements(forName: name).first }

    var childElements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    /// Returns the named child, creating it if needed.
    @discardableResult
    func ensure(_ name: String) -> XMLElement {
        if let c = child(name) { return c }
        let c = XMLElement(name: name)
        addChild(c)
        return c
    }

    func setAttr(_ name: String, _ value: String) {
        if let a = attribute(forName: name) { a.stringValue = value }
        else { addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }

    func removeChildren(named name: String) {
        for c in elements(forName: name).reversed() { removeChild(at: c.index) }
    }
}
