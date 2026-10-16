// SPDX-License-Identifier: GPL-2.0-or-later
// VM-level detail pages: Overview, OS information, Performance, CPUs, Memory, Boot Options.

import Charts
import SwiftUI

struct OverviewPage: View {
    let editor: DomainEditor

    var body: some View {
        let root = editor.root
        let os = root?.child("os")
        let type = os?.child("type")
        DevicePage(editor: editor, title: "Overview", element: nil) {
            Section("Basic Details") {
                Field("Name", editor.text(root, "name"))
                    .disabled(editor.isRunning)
                    .help(editor.isRunning ? "Shut down the VM to rename it." : "")
                ReadOnly("UUID", root?.child("uuid")?.stringValue ?? editor.uuid)
                LabeledContent("Status") {
                    let state = editor.connection.domain(editor.uuid)?.state ?? .noState
                    Label(state.label, systemImage: state.isActive ? "play.circle.fill" : "stop.circle")
                        .foregroundStyle(state.isActive ? .green : .secondary)
                }
                Field("Title", editor.text(root, "title"))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                    TextEditor(text: editor.text(root, "description"))
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.secondary, in: .rect(cornerRadius: 6))
                }
            }
            Section("Hypervisor Details") {
                ReadOnly("Hypervisor", (root?.attr("type") ?? "").uppercased())
                ReadOnly("Architecture", type?.attr("arch") ?? "")
                ReadOnly("Emulator", editor.devices?.child("emulator")?.stringValue ?? "")
                ReadOnly("Chipset", chipset(type?.attr("machine") ?? ""))
                ReadOnly("Firmware", firmware(os))
            }
        }
    }

    private func chipset(_ machine: String) -> String {
        if machine.contains("q35") { return "Q35" }
        if machine.contains("pc") { return "i440FX" }
        return machine
    }

    private func firmware(_ os: XMLElement?) -> String {
        if let loader = os?.child("loader")?.stringValue, !loader.isEmpty {
            return "UEFI: \(loader)"
        }
        if os?.attr("firmware") == "efi" { return "UEFI" }
        return "BIOS"
    }
}

struct OSInfoPage: View {
    let editor: DomainEditor
    @StateVar private var guest: [String: String] = [:]
    @StateVar private var addresses: [(name: String, mac: String, addrs: [String])] = []
    @StateVar private var loading = false

    var body: some View {
        DevicePage(editor: editor, title: "OS information", element: nil) {
            Section("Operating System") {
                ReadOnly("Operating system", osID ?? "Unknown")
                if !guest.isEmpty {
                    ReadOnly("Name", guest["os.pretty-name"] ?? guest["os.name"] ?? "")
                    ReadOnly("Kernel", guest["os.kernel-release"] ?? "")
                    ReadOnly("Hostname", guest["hostname"] ?? "")
                    ReadOnly("Time zone", guest["timezone.name"] ?? "")
                }
            }
            Section("Network") {
                if addresses.isEmpty {
                    Text(editor.isRunning ? "No addresses reported. Install the QEMU guest agent for details."
                                          : "The VM is not running.")
                        .foregroundStyle(.secondary)
                }
                ForEach(addresses, id: \.mac) { a in
                    LabeledContent("\(a.name) (\(a.mac))") { Text(a.addrs.joined(separator: "\n")).textSelection(.enabled) }
                }
            }
            Section {
                Button(loading ? "Querying guest agent…" : "Refresh") { Task { await load() } }
                    .disabled(!editor.isRunning || loading)
            }
        }
        .task { await load() }
    }

    /// libosinfo metadata, e.g. http://ubuntu.com/ubuntu/24.04 -> ubuntu 24.04
    private var osID: String? {
        guard let meta = editor.root?.child("metadata"),
              let os = (try? meta.nodes(forXPath: ".//*[local-name()='os']"))?.first as? XMLElement,
              let id = os.attr("id") else { return nil }
        return id
    }

    private func load() async {
        guard editor.isRunning else { return }
        loading = true
        let uuid = editor.uuid
        let result = try? await editor.connection.withConnection { conn -> ([String: String], [(String, String, [String])]) in
            let d = try conn.domain(uuid: uuid)
            return (d.guestInfo(), d.interfaceAddresses().map { ($0.name, $0.mac, $0.addrs) })
        }
        guest = result?.0 ?? [:]
        addresses = result?.1.map { (name: $0.0, mac: $0.1, addrs: $0.2) } ?? []
        loading = false
    }
}

struct PerformancePage: View {
    let editor: DomainEditor

    private var points: [StatsPoint] { editor.connection.history[editor.uuid] ?? [] }

    var body: some View {
        DevicePage(editor: editor, title: "Performance", element: nil) {
            if points.isEmpty {
                Text(editor.isRunning ? "Collecting statistics…" : "The VM is not running.").foregroundStyle(.secondary)
            } else {
                Section("CPU usage") { chart([("CPU", \.cpuPercent)], unit: "%", max: 100) }
                Section("Memory usage") { chart([("Memory", \.memoryPercent)], unit: "%", max: 100) }
                Section("Disk I/O") { chart([("Read", \.diskReadBps), ("Write", \.diskWriteBps)], unit: "B/s") }
                Section("Network I/O") { chart([("In", \.netRxBps), ("Out", \.netTxBps)], unit: "B/s") }
            }
        }
    }

    private func chart(_ series: [(String, KeyPath<StatsPoint, Double>)], unit: String, max: Double? = nil) -> some View {
        let last = series.map { name, kp in "\(name) \(format(points.last?[keyPath: kp] ?? 0, unit))" }.joined(separator: "   ")
        return VStack(alignment: .leading, spacing: 4) {
            Text(last).font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(series, id: \.0) { name, kp in
                    ForEach(points) { p in
                        AreaMark(x: .value("Time", p.time), y: .value(name, p[keyPath: kp]))
                            .foregroundStyle(by: .value("Series", name))
                            .opacity(0.25)
                        LineMark(x: .value("Time", p.time), y: .value(name, p[keyPath: kp]))
                            .foregroundStyle(by: .value("Series", name))
                    }
                }
            }
            .chartYScale(domain: 0 ... (max ?? Swift.max(1, points.map { p in series.map { p[keyPath: $0.1] }.max() ?? 0 }.max() ?? 1)))
            .chartXAxis(.hidden)
            .chartLegend(series.count > 1 ? .visible : .hidden)
            .frame(height: 90)
        }
    }

    private func format(_ v: Double, _ unit: String) -> String {
        unit == "%" ? String(format: "%.0f%%", v) : ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary) + "/s"
    }
}

struct CPUsPage: View {
    let editor: DomainEditor

    var body: some View {
        let root = editor.root
        let vcpu = root?.child("vcpu")
        let cpu = root?.child("cpu")
        let topology = cpu?.child("topology")
        DevicePage(editor: editor, title: "CPUs", element: nil) {
            Section {
                if let node = editor.connection.nodeInfo {
                    ReadOnly("Logical host CPUs", "\(node.cpus)")
                }
                NumberField(title: "vCPU allocation", value: currentBinding(vcpu), range: 1 ... maxVCPUs(vcpu))
                NumberField(title: "Maximum allocation", value: maxBinding(vcpu), range: 1 ... 512)
            }
            Section("Configuration") {
                Picker("CPU model", selection: modeBinding()) {
                    Text("Hypervisor default").tag("default")
                    Text("Copy host CPU configuration (host-passthrough)").tag("host-passthrough")
                    Text("Host model (host-model)").tag("host-model")
                    Text("Custom model").tag("custom")
                    Text("Maximum (max)").tag("maximum")
                }
                if cpu?.attr("mode") == "custom" {
                    Field("Model", editor.text(cpu, "model"), prompt: "e.g. Skylake-Client-IBRS")
                }
            }
            Section("Topology") {
                Toggle("Manually set CPU topology", isOn: topologyToggle())
                if let topology {
                    NumberField(title: "Sockets", value: editor.number(editor.attr(topology, "sockets"), default: 1), range: 1 ... 64)
                    NumberField(title: "Dies", value: editor.number(editor.attr(topology, "dies"), default: 1), range: 1 ... 64)
                    NumberField(title: "Cores", value: editor.number(editor.attr(topology, "cores"), default: 1), range: 1 ... 256)
                    NumberField(title: "Threads", value: editor.number(editor.attr(topology, "threads"), default: 1), range: 1 ... 8)
                }
            }
        }
    }

    private func maxVCPUs(_ vcpu: XMLElement?) -> Int { max(1, Int(vcpu?.stringValue ?? "") ?? 1) }

    private func currentBinding(_ vcpu: XMLElement?) -> Binding<Int> {
        Binding(
            get: { _ = editor.revision; return Int(vcpu?.attr("current") ?? vcpu?.stringValue ?? "1") ?? 1 },
            set: { v in
                guard let vcpu else { return }
                let maxV = Int(vcpu.stringValue ?? "") ?? v
                if v >= maxV { vcpu.removeAttribute(forName: "current"); vcpu.stringValue = String(v) }
                else { vcpu.setAttr("current", String(v)) }
                editor.touch(vcpu)
            })
    }

    private func maxBinding(_ vcpu: XMLElement?) -> Binding<Int> {
        Binding(
            get: { _ = editor.revision; return Int(vcpu?.stringValue ?? "1") ?? 1 },
            set: { v in
                guard let vcpu else { return }
                vcpu.stringValue = String(v)
                if let cur = Int(vcpu.attr("current") ?? ""), cur >= v { vcpu.removeAttribute(forName: "current") }
                editor.touch(vcpu)
            })
    }

    private func modeBinding() -> Binding<String> {
        Binding(
            get: {
                _ = editor.revision
                guard let cpu = editor.root?.child("cpu") else { return "default" }
                if cpu.attr("mode") == "maximum" { return "maximum" }
                return cpu.attr("mode") ?? (cpu.child("model") != nil ? "custom" : "default")
            },
            set: { mode in
                guard let root = editor.root else { return }
                if mode == "default" {
                    // Keep a topology-only <cpu> element.
                    if let cpu = root.child("cpu") {
                        cpu.removeAttribute(forName: "mode")
                        cpu.removeAttribute(forName: "check")
                        cpu.removeAttribute(forName: "migratable")
                        cpu.removeChildren(named: "model")
                        if cpu.childElements.isEmpty { root.removeChild(at: cpu.index) }
                    }
                } else {
                    let cpu = root.ensure("cpu")
                    cpu.setAttr("mode", mode)
                    if mode != "custom" { cpu.removeChildren(named: "model") }
                    else if cpu.child("model") == nil { cpu.ensure("model").stringValue = "qemu64" }
                }
                editor.touch(root)
            })
    }

    private func topologyToggle() -> Binding<Bool> {
        Binding(
            get: { _ = editor.revision; return editor.root?.child("cpu")?.child("topology") != nil },
            set: { on in
                guard let root = editor.root else { return }
                let cpu = root.ensure("cpu")
                if on {
                    let n = Int(root.child("vcpu")?.stringValue ?? "1") ?? 1
                    let t = cpu.ensure("topology")
                    t.setAttr("sockets", "1"); t.setAttr("dies", "1"); t.setAttr("cores", String(n)); t.setAttr("threads", "1")
                } else {
                    cpu.removeChildren(named: "topology")
                    if cpu.childElements.isEmpty, cpu.attributes?.isEmpty ?? true { root.removeChild(at: cpu.index) }
                }
                editor.touch(root)
            })
    }
}

struct MemoryPage: View {
    let editor: DomainEditor

    var body: some View {
        let root = editor.root
        DevicePage(editor: editor, title: "Memory", element: nil) {
            Section {
                if let node = editor.connection.nodeInfo {
                    ReadOnly("Total host memory", "\(node.memoryKiB / 1024) MiB")
                }
                NumberField(title: "Current allocation", value: memBinding("currentMemory"), range: 64 ... 4_194_304, unit: "MiB")
                NumberField(title: "Maximum allocation", value: memBinding("memory"), range: 64 ... 4_194_304, unit: "MiB")
            }
            Section {
                Toggle("Enable shared memory", isOn: sharedBinding(root))
                Text("Required for virtiofs filesystem sharing.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func memBinding(_ name: String) -> Binding<Int> {
        Binding(
            get: {
                _ = editor.revision
                let el = editor.root?.child(name) ?? editor.root?.child("memory")
                return MemoryUnits.mib(el)
            },
            set: { v in
                guard let root = editor.root else { return }
                MemoryUnits.set(root.ensure(name), mib: v)
                // Keep current <= maximum.
                if name == "memory", let cur = root.child("currentMemory"), MemoryUnits.mib(cur) > v { MemoryUnits.set(cur, mib: v) }
                if name == "currentMemory", let mx = root.child("memory"), MemoryUnits.mib(mx) < v { MemoryUnits.set(mx, mib: v) }
                editor.touch(root)
            })
    }

    private func sharedBinding(_ root: XMLElement?) -> Binding<Bool> {
        Binding(
            get: { _ = editor.revision; return root?.child("memoryBacking")?.child("access")?.attr("mode") == "shared" },
            set: { on in
                guard let root else { return }
                if on {
                    let mb = root.ensure("memoryBacking")
                    mb.ensure("source").setAttr("type", "memfd")
                    mb.ensure("access").setAttr("mode", "shared")
                } else if let mb = root.child("memoryBacking") {
                    mb.removeChildren(named: "access")
                    if mb.child("source")?.attr("type") == "memfd" { mb.removeChildren(named: "source") }
                    if mb.childElements.isEmpty { root.removeChild(at: mb.index) }
                }
                editor.touch(root)
            })
    }
}

struct BootPage: View {
    @Bindable var editor: DomainEditor

    var body: some View {
        let os = editor.root?.child("os")
        DevicePage(editor: editor, title: "Boot Options", element: nil) {
            Section("Autostart") {
                Toggle("Start virtual machine on host boot up", isOn: $editor.autostart)
            }
            Section("Boot device order") {
                Toggle("Enable boot menu", isOn: bootMenuBinding(os))
                ForEach(bootables, id: \.self) { el in
                    HStack {
                        Toggle(isOn: enabledBinding(el)) { Text(label(el)) }
                        Spacer()
                        Button("Move Up", systemImage: "chevron.up") { move(el, by: -1) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .disabled(order(el) == nil || order(el) == 1)
                        Button("Move Down", systemImage: "chevron.down") { move(el, by: 1) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .disabled(order(el) == nil || order(el) == bootables.compactMap(order).max())
                    }
                }
            }
            Section("Direct kernel boot") {
                Toggle("Enable direct kernel boot", isOn: kernelToggle(os))
                if os?.child("kernel") != nil {
                    Field("Kernel path", editor.text(os, "kernel"))
                    Field("Initrd path", editor.text(os, "initrd"))
                    Field("DTB path", editor.text(os, "dtb"))
                    Field("Kernel args", editor.text(os, "cmdline"))
                }
            }
        }
        .onAppear(perform: migrateLegacyBootOrder)
    }

    /// Disks, NICs and host devices, ordered by boot order then XML order.
    private var bootables: [XMLElement] {
        _ = editor.revision
        let devs = (editor.devices?.childElements ?? []).filter { ["disk", "interface", "hostdev", "redirdev"].contains($0.name ?? "") }
        return devs.enumerated().sorted { a, b in
            switch (order(a.element), order(b.element)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    private func order(_ el: XMLElement) -> Int? { Int(el.child("boot")?.attr("order") ?? "") }

    private func label(_ el: XMLElement) -> String {
        editor.hardwareItems.first { $0.element === el }?.label ?? (el.name ?? "")
    }

    private func renumber(_ list: [XMLElement]) {
        for (i, el) in list.enumerated() { el.ensure("boot").setAttr("order", String(i + 1)) }
        editor.touch(editor.devices)
    }

    private func enabledBinding(_ el: XMLElement) -> Binding<Bool> {
        Binding(
            get: { _ = editor.revision; return order(el) != nil },
            set: { on in
                var enabled = bootables.filter { order($0) != nil }
                if on { enabled.append(el) } else {
                    el.removeChildren(named: "boot")
                    enabled.removeAll { $0 === el }
                }
                renumber(enabled)
            })
    }

    private func move(_ el: XMLElement, by delta: Int) {
        var enabled = bootables.filter { order($0) != nil }
        guard let i = enabled.firstIndex(where: { $0 === el }) else { return }
        let j = i + delta
        guard j >= 0, j < enabled.count else { return }
        enabled.swapAt(i, j)
        renumber(enabled)
    }

    /// Converts <os><boot dev=…/> to per-device boot order, as virt-manager does.
    private func migrateLegacyBootOrder() {
        guard let os = editor.root?.child("os"), let devices = editor.devices else { return }
        let legacy = os.elements(forName: "boot").compactMap { $0.attr("dev") }
        guard !legacy.isEmpty, !devices.childElements.contains(where: { $0.child("boot") != nil }) else { return }
        var ordered: [XMLElement] = []
        for dev in legacy {
            let match: (XMLElement) -> Bool = switch dev {
            case "hd": { $0.name == "disk" && ($0.attr("device") ?? "disk") == "disk" }
            case "cdrom": { $0.name == "disk" && $0.attr("device") == "cdrom" }
            case "fd": { $0.name == "disk" && $0.attr("device") == "floppy" }
            case "network": { $0.name == "interface" }
            default: { _ in false }
            }
            if let el = devices.childElements.first(where: match) { ordered.append(el) }
        }
        guard !ordered.isEmpty else { return }
        os.removeChildren(named: "boot")
        for (i, el) in ordered.enumerated() { el.ensure("boot").setAttr("order", String(i + 1)) }
        // Not a user edit: leave isDirty alone, but redraw.
        editor.touch(nil)
    }

    private func bootMenuBinding(_ os: XMLElement?) -> Binding<Bool> {
        Binding(
            get: { _ = editor.revision; return os?.child("bootmenu")?.attr("enable") == "yes" },
            set: { on in
                guard let os else { return }
                if on { os.ensure("bootmenu").setAttr("enable", "yes") } else { os.removeChildren(named: "bootmenu") }
                editor.touch(os)
            })
    }

    private func kernelToggle(_ os: XMLElement?) -> Binding<Bool> {
        Binding(
            get: { _ = editor.revision; return os?.child("kernel") != nil },
            set: { on in
                guard let os else { return }
                if on { os.ensure("kernel").stringValue = "" } else {
                    for n in ["kernel", "initrd", "cmdline", "dtb"] { os.removeChildren(named: n) }
                }
                editor.touch(os)
            })
    }
}
