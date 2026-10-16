// SPDX-License-Identifier: GPL-2.0-or-later
// "Add New Virtual Hardware" dialog. Most categories reuse the device detail
// pages on a scratch element; storage, network and host devices have their own forms.

import SwiftUI

enum HardwareCategory: String, CaseIterable, Identifiable {
    case storage = "Storage", controller = "Controller", network = "Network", input = "Input"
    case graphics = "Graphics", sound = "Sound", serial = "Serial", parallel = "Parallel"
    case console = "Console", channel = "Channel", usbHost = "USB Host Device", pciHost = "PCI Host Device"
    case video = "Video", watchdog = "Watchdog", filesystem = "Filesystem", smartcard = "Smartcard"
    case usbRedir = "USB Redirection", tpm = "TPM", rng = "RNG", panic = "Panic Notifier", vsock = "VirtIO VSOCK"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .storage: "internaldrive"
        case .controller: "square.stack.3d.up"
        case .network: "network"
        case .input: "computermouse"
        case .graphics: "display"
        case .sound: "speaker.wave.2"
        case .serial, .parallel, .channel: "cable.connector"
        case .console: "terminal"
        case .usbHost, .pciHost: "cable.connector.horizontal"
        case .video: "rectangle.on.rectangle"
        case .watchdog: "timer"
        case .filesystem: "folder"
        case .smartcard: "creditcard"
        case .usbRedir: "arrow.left.arrow.right"
        case .tpm: "lock.shield"
        case .rng: "dice"
        case .panic: "exclamationmark.triangle"
        case .vsock: "point.3.connected.trianglepath.dotted"
        }
    }

    /// Default element for the categories edited through the device pages.
    func template(isARM: Bool, nextSerialPort: Int) -> String? {
        switch self {
        case .controller: "<controller type='scsi' model='virtio-scsi'/>"
        case .input: "<input type='tablet' bus='usb'/>"
        case .graphics: "<graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics>"
        case .sound: "<sound model='ich9'/>"
        case .serial: "<serial type='pty'><target port='\(nextSerialPort)'/></serial>"
        case .parallel: "<parallel type='pty'/>"
        case .console: "<console type='pty'><target type='virtio'/></console>"
        case .channel: "<channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>"
        case .video: "<video><model type='virtio' heads='1'/></video>"
        case .watchdog: "<watchdog model='i6300esb' action='reset'/>"
        case .filesystem: "<filesystem type='mount' accessmode='passthrough'><driver type='virtiofs'/><source dir=''/><target dir=''/></filesystem>"
        case .smartcard: "<smartcard mode='host'/>"
        case .usbRedir: "<redirdev bus='usb' type='spicevmc'/>"
        case .tpm: "<tpm model='\(isARM ? "tpm-tis" : "tpm-crb")'><backend type='emulator' version='2.0'/></tpm>"
        case .rng: "<rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>"
        case .panic: isARM ? "<panic model='pvpanic'/>" : "<panic model='isa'/>"
        case .vsock: "<vsock model='virtio'><cid auto='yes'/></vsock>"
        default: nil
        }
    }

    var kind: HardwareKind {
        switch self {
        case .controller: .controller
        case .input: .input
        case .graphics: .graphics
        case .sound: .sound
        case .serial, .parallel, .console, .channel: .char
        case .video: .video
        case .watchdog: .watchdog
        case .filesystem: .filesystem
        case .smartcard: .smartcard
        case .usbRedir: .redirdev
        case .tpm: .tpm
        case .rng: .rng
        case .panic: .panic
        case .vsock: .vsock
        default: .overview
        }
    }
}

struct AddHardwareSheet: View {
    let editor: DomainEditor
    @Environment(\.dismiss) private var dismiss

    @StateVar private var category: HardwareCategory = .storage
    @StateVar private var scratch: DomainEditor?
    @StateVar private var storage = StorageForm()
    @StateVar private var nic = NICForm()
    @StateVar private var hostDevices: [HostDeviceRow] = []
    @StateVar private var selectedHostDevice: HostDeviceRow.ID?
    @StateVar private var networks: [String] = []
    @StateVar private var defaultPool: PoolRow?
    @StateVar private var error: String?
    @StateVar private var busy = false
    @StateVar private var askConfigOnly = false
    @StateVar private var pendingXML: [String] = []
    @StateVar private var browse = false

    private var isARM: Bool { editor.root?.child("os")?.child("type")?.attr("arch")?.hasPrefix("a") ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(HardwareCategory.allCases, selection: Binding(get: { category }, set: { if let c = $0 { category = c } })) { c in
                    Label(c.rawValue, systemImage: c.icon).tag(c)
                }
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 240)
                form.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
                else if editor.isDirty { Text("Unapplied changes in Details will be discarded.").foregroundStyle(.orange) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Finish") { Task { await finish() } }.keyboardShortcut(.defaultAction).disabled(busy)
            }
            .padding()
        }
        .frame(width: 820, height: 600)
        .onChange(of: category, initial: true) { _, c in prepare(c) }
        .task { await loadContext() }
        .alert("This device could not be attached to the running machine. Would you like to make the device available after the next guest shutdown?",
               isPresented: $askConfigOnly) {
            Button("Yes") { Task { await attach(pendingXML, scope: .config) } }
            Button("No", role: .cancel) {}
        }
    }

    // MARK: Forms

    @ViewBuilder private var form: some View {
        switch category {
        case .storage: storageForm
        case .network: networkForm
        case .usbHost, .pciHost: hostDeviceForm
        default:
            if let scratch, let el = scratch.devices?.childElements.first {
                DevicePage(editor: scratch, title: category.rawValue, element: el) {
                    switch category {
                    case .controller: AddControllerFields(editor: scratch, el: el)
                    case .input: InputFields(editor: scratch, el: el, editable: true)
                    case .usbRedir:
                        Choice("Type", scratch.attr(el, "type"), [("spicevmc", "Spice channel"), ("tcp", "TCP")])
                    case .smartcard:
                        Choice("Mode", scratch.attr(el, "mode"), Options.smartcardMode)
                    case .console where true:
                        CharFields(editor: scratch, el: el)
                    case .channel:
                        CharFields(editor: scratch, el: el)
                    default:
                        DeviceDetailsBody(editor: scratch, kind: category.kind, el: el)
                    }
                }
            }
        }
    }

    private var storageForm: some View {
        Form {
            Section("Storage") {
                Picker("", selection: $storage.create) {
                    Text("Create a disk image for the virtual machine").tag(true)
                    Text("Select or create custom storage").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(storage.device == "cdrom" || storage.device == "floppy")
                if storage.create {
                    LabeledContent("Size") {
                        HStack {
                            TextField("", value: $storage.sizeGiB, format: .number.precision(.fractionLength(1))).frame(width: 80)
                            Stepper("", value: $storage.sizeGiB, in: 0.1 ... 1_000_000).labelsHidden()
                            Text("GiB")
                        }
                    }
                    Text(defaultPool.map { "\(Pretty.gib($0.info.available)) available in the default location" } ?? "Unknown GiB available in the default location")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        TextField("Path", text: $storage.path, prompt: Text(storage.device == "cdrom" ? "Empty drive" : "/path/to/disk.qcow2"))
                        Button("Manage…") { browse = true }
                    }
                }
            }
            Section {
                Picker("Device type", selection: $storage.device) {
                    Label("Disk device", systemImage: "internaldrive").tag("disk")
                    Label("CDROM device", systemImage: "opticaldisc").tag("cdrom")
                    Label("Floppy device", systemImage: "opticaldiscdrive").tag("floppy")
                    Label("LUN Passthrough", systemImage: "internaldrive").tag("lun")
                }
                Picker("Bus type", selection: $storage.bus) {
                    ForEach(storage.allowedBuses, id: \.self) { Text(Pretty.bus($0)).tag($0) }
                }
            }
            Section("Advanced options") {
                Choice("Cache mode", $storage.cache, Options.cache)
                Choice("Discard mode", $storage.discard, Options.discard)
                Toggle("Readonly", isOn: $storage.readonly)
                Toggle("Shareable", isOn: $storage.shareable)
                if storage.bus == "usb" { Toggle("Removable", isOn: $storage.removable) }
                TextField("Serial", text: $storage.serial)
            }
        }
        .formStyle(.grouped)
        .onChange(of: storage.device) {
            if storage.device == "cdrom" || storage.device == "floppy" { storage.create = false }
            storage.bus = defaultBus(for: storage.device)
        }
        .sheet(isPresented: $browse) {
            StorageBrowser(connection: editor.connection, purpose: storage.device == "cdrom" ? .media : .disk) { storage.path = $0 }
        }
    }

    private var networkForm: some View {
        Form {
            Section("Network") {
                Picker("Network source", selection: $nic.source) {
                    ForEach(networks, id: \.self) { Text("Virtual network '\($0)'").tag("network:\($0)") }
                    Text("Bridge device…").tag("bridge")
                    Text("Macvtap device…").tag("direct")
                    Text("Usermode networking").tag("user")
                }
                if nic.source == "bridge" { TextField("Device name", text: $nic.device, prompt: Text("br0")) }
                if nic.source == "direct" {
                    TextField("Device name", text: $nic.device, prompt: Text("eth0"))
                    Choice("Source mode", $nic.mode, Options.macvtapMode)
                }
                Toggle("MAC address", isOn: $nic.setMAC)
                if nic.setMAC { TextField("", text: $nic.mac).labelsHidden() }
                Choice("Device model", $nic.model, Options.nicModel)
            }
        }
        .formStyle(.grouped)
    }

    private var hostDeviceForm: some View {
        VStack(alignment: .leading) {
            Text(category == .usbHost ? "USB Host Device" : "PCI Host Device").font(.title3).bold()
            Table(hostDevices.filter { $0.type == (category == .usbHost ? "usb" : "pci") }, selection: $selectedHostDevice) {
                TableColumn("Host Device", value: \.label)
                TableColumn("ID", value: \.ids).width(120)
            }
            Text("The device is detached from the host while the VM uses it.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: Logic

    private func prepare(_ c: HardwareCategory) {
        error = nil
        let serialPorts = editor.devices?.elements(forName: "serial").compactMap { Int($0.child("target")?.attr("port") ?? "") } ?? []
        if let tmpl = c.template(isARM: isARM, nextSerialPort: (serialPorts.max() ?? -1) + 1), let el = try? XMLElement(xmlString: tmpl) {
            let s = DomainEditor(connection: editor.connection, uuid: editor.uuid)
            s.setScratch(el)
            scratch = s
        } else {
            scratch = nil
        }
    }

    private func defaultBus(for device: String) -> String {
        if let existing = editor.devices?.elements(forName: "disk").first(where: { ($0.attr("device") ?? "disk") == device }),
           let bus = existing.child("target")?.attr("bus") { return bus }
        switch device {
        case "floppy": return "fdc"
        case "lun": return "scsi"
        case "cdrom": return isARM ? "scsi" : "sata"
        default: return "virtio"
        }
    }

    private func loadContext() async {
        storage.bus = defaultBus(for: "disk")
        nic.mac = NICForm.randomMAC()
        let local = editor.connection.isLocal
        let result = try? await editor.connection.withConnection { conn -> ([String], PoolRow?, [HostDeviceRow]) in
            let nets = ((try? conn.networks()) ?? []).filter(\.isActive).map(\.name)
            var pool: PoolRow?
            if let p = try? conn.storagePool(named: "default"), let info = try? p.info() {
                pool = PoolRow(name: "default", type: "dir", info: info, active: p.isActive, autostart: p.autostart, path: "", xml: "")
            }
            var devs: [HostDeviceRow] = []
            for cap in ["usb_device", "pci"] {
                for d in (try? conn.nodeDevices(capability: cap)) ?? [] { if let row = HostDeviceRow(xml: d.xml) { devs.append(row) } }
            }
            return (nets, pool, devs)
        }
        networks = result?.0 ?? []
        defaultPool = result?.1
        hostDevices = result?.2 ?? []
        nic.source = networks.contains("default") ? "network:default" : (networks.first.map { "network:\($0)" } ?? (local ? "user" : "bridge"))
    }

    private func usedTargets() async -> Set<String> {
        var used = Set(editor.devices?.elements(forName: "disk").compactMap { $0.child("target")?.attr("dev") } ?? [])
        if let live = try? await editor.connection.domainXML(uuid: editor.uuid, inactive: false),
           let doc = try? XMLDocument(xmlString: live) {
            for t in doc.rootElement()?.all(".//disk/target") ?? [] { if let d = t.attr("dev") { used.insert(d) } }
        }
        return used
    }

    private func finish() async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            var xmls: [String] = []
            switch category {
            case .storage: xmls = try await storageXML()
            case .network: xmls = [nic.xml]
            case .usbHost, .pciHost:
                guard let id = selectedHostDevice, let dev = hostDevices.first(where: { $0.id == id }) else {
                    throw LibvirtError(message: "Please select a host device.")
                }
                xmls = [dev.hostdevXML]
            default:
                guard let el = scratch?.devices?.childElements.first else { return }
                if category == .filesystem {
                    guard let src = el.child("source")?.attr("dir"), !src.isEmpty, let tgt = el.child("target")?.attr("dir"), !tgt.isEmpty else {
                        throw LibvirtError(message: "A source path and a target path must be specified.")
                    }
                }
                xmls = [el.xmlString]
            }
            await attach(xmls, scope: editor.isRunning ? .both : .config)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func attach(_ xmls: [String], scope: Domain.Scope) async {
        let uuid = editor.uuid
        do {
            try await editor.connection.withConnection { conn in
                let d = try conn.domain(uuid: uuid)
                for x in xmls { try d.attachDevice(x, scope: scope) }
            }
            await editor.load()
            if scope == .config && editor.isRunning {
                editor.applyMessage = "The device will be added after the next guest shutdown."
            }
            dismiss()
        } catch {
            if scope == .both {
                pendingXML = xmls
                askConfigOnly = true
            } else {
                self.error = "Unable to add device: \(error.localizedDescription)"
            }
        }
    }

    private func storageXML() async throws -> [String] {
        var path = storage.path.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("file://") { path = String(path.dropFirst(7)) }
        if storage.create {
            // New volume in the default pool, named after the VM.
            let vmName = editor.name
            let size = storage.sizeGiB
            let format = Preferences.shared.defaultStorageFormat
            path = try await editor.connection.withConnection { conn in
                let pool = try conn.storagePool(named: "default")
                if !pool.isActive { try pool.start() }
                try? pool.refresh()
                let existing = Set(((try? pool.volumes()) ?? []).map(\.name))
                let ext = format == "raw" ? ".img" : ".qcow2"
                var name = vmName + ext, n = 1
                while existing.contains(name) { name = "\(vmName)-\(n)\(ext)"; n += 1 }
                let cap = UInt64(size * 1_073_741_824)
                let xml = VolumeXML.make(name: name, format: format, capacityBytes: cap, allocationBytes: format == "raw" ? cap : 0)
                return try pool.createVolume(xml: xml).path
            }
        } else if path.isEmpty, storage.device == "disk" || storage.device == "lun" {
            throw LibvirtError(message: "A storage path must be specified.")
        }

        let used = await usedTargets()
        let prefix: String = switch storage.bus {
        case "virtio": "vd"
        case "fdc": "fd"
        case "ide": "hd"
        default: "sd"
        }
        var target = ""
        for i in 0 ..< 702 {
            let letters = i < 26 ? String(UnicodeScalar(97 + i)!) : String(UnicodeScalar(96 + i / 26)!) + String(UnicodeScalar(97 + i % 26)!)
            if !used.contains(prefix + letters) { target = prefix + letters; break }
        }
        if storage.bus == "nvme" { target = "nvme0n\(used.filter { $0.hasPrefix("nvme") }.count + 1)" }

        let isBlock = path.hasPrefix("/dev/")
        var driver = "<driver name='qemu' type='\(isBlock || storage.device != "disk" || path.hasSuffix(".iso") || path.hasSuffix(".img") || path.hasSuffix(".raw") ? "raw" : "qcow2")'"
        if !storage.cache.isEmpty { driver += " cache='\(storage.cache)'" }
        if !storage.discard.isEmpty { driver += " discard='\(storage.discard)'" }
        else if storage.device == "disk" { driver += " discard='unmap'" }
        driver += "/>"
        var disk = "<disk type='\(isBlock ? "block" : "file")' device='\(storage.device)'>\(path.isEmpty ? "" : driver)"
        if !path.isEmpty { disk += isBlock ? "<source dev='\(path.xmlEscaped)'/>" : "<source file='\(path.xmlEscaped)'/>" }
        disk += "<target dev='\(target)' bus='\(storage.bus)'\(storage.removable && storage.bus == "usb" ? " removable='on'" : "")/>"
        if storage.readonly || storage.device == "cdrom" { disk += "<readonly/>" }
        if storage.shareable { disk += "<shareable/>" }
        if !storage.serial.isEmpty { disk += "<serial>\(storage.serial.xmlEscaped)</serial>" }
        disk += "</disk>"

        var out: [String] = []
        let controllers = editor.devices?.elements(forName: "controller") ?? []
        if storage.bus == "scsi", !controllers.contains(where: { $0.attr("type") == "scsi" }) {
            out.append("<controller type='scsi' model='virtio-scsi' index='0'/>")
        }
        if storage.bus == "nvme", !controllers.contains(where: { $0.attr("type") == "nvme" }) {
            out.append("<controller type='nvme' index='0'><serial>0</serial></controller>")
        }
        out.append(disk)
        return out
    }
}

/// The body of a device page without the DevicePage chrome (used by Add Hardware).
struct DeviceDetailsBody: View {
    let editor: DomainEditor
    let kind: HardwareKind
    let el: XMLElement

    var body: some View {
        switch kind {
        case .graphics: GraphicsFields(editor: editor, el: el)
        case .sound: Choice("Model", editor.attr(el, "model"), Options.soundModel)
        case .char: CharFields(editor: editor, el: el)
        case .video: VideoFields(editor: editor, el: el)
        case .watchdog:
            Choice("Model", editor.attr(el, "model"), Options.watchdogModel)
            Choice("Action", editor.attr(el, "action", default: "reset"), Options.watchdogAction)
        case .filesystem: FilesystemFields(editor: editor, el: el)
        case .tpm: TPMFields(editor: editor, el: el)
        case .rng: RNGFields(editor: editor, el: el)
        case .panic: Choice("Model", editor.attr(el, "model"), Options.panicModel)
        case .vsock: VSockFields(editor: editor, el: el)
        default: EmptyView()
        }
    }
}

struct AddControllerFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        Choice("Type", Binding(
            get: { _ = editor.revision; return el.attr("type") ?? "scsi" },
            set: { t in
                el.setAttr("type", t)
                switch t {
                case "scsi": el.setAttr("model", "virtio-scsi")
                case "usb": el.setAttr("model", "qemu-xhci")
                default: el.removeAttribute(forName: "model")
                }
                editor.touch(el)
            }), Options.controllerType)
        switch el.attr("type") {
        case "usb": Choice("Model", editor.attr(el, "model"), Options.usbModel)
        case "scsi": Choice("Model", editor.attr(el, "model"), Options.scsiModel)
        default: EmptyView()
        }
    }
}

struct StorageForm {
    var create = true
    var sizeGiB = 20.0
    var path = ""
    var device = "disk"
    var bus = "virtio"
    var cache = ""
    var discard = ""
    var readonly = false
    var shareable = false
    var removable = false
    var serial = ""

    var allowedBuses: [String] {
        switch device {
        case "cdrom": ["sata", "scsi", "usb", "ide"]
        case "floppy": ["fdc"]
        case "lun": ["scsi"]
        default: ["virtio", "sata", "scsi", "usb", "nvme", "ide", "sd"]
        }
    }
}

struct NICForm {
    var source = "network:default"
    var device = ""
    var mode = "bridge"
    var setMAC = true
    var mac = ""
    var model = "virtio"

    static func randomMAC() -> String {
        String(format: "52:54:00:%02x:%02x:%02x", Int.random(in: 0 ... 255), Int.random(in: 0 ... 255), Int.random(in: 0 ... 255))
    }

    var xml: String {
        var x: String
        if source.hasPrefix("network:") {
            x = "<interface type='network'><source network='\(String(source.dropFirst(8)).xmlEscaped)'/>"
        } else if source == "bridge" {
            x = "<interface type='bridge'><source bridge='\((device.isEmpty ? "br0" : device).xmlEscaped)'/>"
        } else if source == "direct" {
            x = "<interface type='direct'><source dev='\((device.isEmpty ? "eth0" : device).xmlEscaped)' mode='\(mode)'/>"
        } else {
            x = "<interface type='user'>"
        }
        if setMAC, !mac.isEmpty { x += "<mac address='\(mac.xmlEscaped)'/>" }
        x += "<model type='\(model)'/></interface>"
        return x
    }
}

struct HostDeviceRow: Identifiable, Hashable {
    var id: String
    var type: String       // usb / pci
    var label: String
    var ids: String
    var hostdevXML: String

    init?(xml: String) {
        guard let root = (try? XMLDocument(xmlString: xml))?.rootElement(), let cap = root.child("capability") else { return nil }
        let name = root.child("name")?.stringValue ?? ""
        id = name
        let product = cap.child("product"), vendor = cap.child("vendor")
        let pid = product?.attr("id") ?? "", vid = vendor?.attr("id") ?? ""
        let desc = [vendor?.stringValue, product?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        ids = "\(vid.replacingOccurrences(of: "0x", with: "")):\(pid.replacingOccurrences(of: "0x", with: ""))"
        switch cap.attr("type") {
        case "usb_device":
            type = "usb"
            let bus = cap.child("bus")?.stringValue ?? "0", dev = cap.child("device")?.stringValue ?? "0"
            label = "\(String(format: "%03d", Int(bus) ?? 0)):\(String(format: "%03d", Int(dev) ?? 0)) \(desc.isEmpty ? name : desc)"
            hostdevXML = "<hostdev mode='subsystem' type='usb' managed='yes'><source><vendor id='\(vid)'/><product id='\(pid)'/></source></hostdev>"
        case "pci":
            type = "pci"
            let d = cap.child("domain")?.stringValue ?? "0", b = cap.child("bus")?.stringValue ?? "0"
            let s = cap.child("slot")?.stringValue ?? "0", f = cap.child("function")?.stringValue ?? "0"
            let addr = String(format: "%04x:%02x:%02x.%x", Int(d) ?? 0, Int(b) ?? 0, Int(s) ?? 0, Int(f) ?? 0)
            label = "\(addr) \(desc.isEmpty ? name : desc)"
            hostdevXML = "<hostdev mode='subsystem' type='pci' managed='yes'><source><address domain='0x\(String(Int(d) ?? 0, radix: 16))' bus='0x\(String(Int(b) ?? 0, radix: 16))' slot='0x\(String(Int(s) ?? 0, radix: 16))' function='0x\(String(Int(f) ?? 0, radix: 16))'/></source></hostdev>"
        default:
            return nil
        }
    }
}
