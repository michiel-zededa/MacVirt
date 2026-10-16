// SPDX-License-Identifier: GPL-2.0-or-later
// Detail pages for individual devices. Each page edits its XMLElement in place.

import SwiftUI

enum Options {
    static let diskBus: [(String, String)] = [
        ("virtio", "VirtIO"), ("sata", "SATA"), ("scsi", "SCSI"), ("usb", "USB"), ("nvme", "NVMe"), ("ide", "IDE"), ("sd", "SD"), ("fdc", "Floppy"),
    ]
    static let cache: [(String, String)] = [
        ("", "Hypervisor default"), ("none", "none"), ("writethrough", "writethrough"), ("writeback", "writeback"),
        ("directsync", "directsync"), ("unsafe", "unsafe"),
    ]
    static let discard: [(String, String)] = [("", "Hypervisor default"), ("ignore", "ignore"), ("unmap", "unmap")]
    static let detectZeroes: [(String, String)] = [("", "Hypervisor default"), ("off", "off"), ("on", "on"), ("unmap", "unmap")]
    static let io: [(String, String)] = [("", "Hypervisor default"), ("native", "native"), ("threads", "threads"), ("io_uring", "io_uring")]
    static let diskFormat: [(String, String)] = [("raw", "raw"), ("qcow2", "qcow2"), ("vmdk", "vmdk"), ("vdi", "vdi"), ("qed", "qed")]
    static let nicModel: [(String, String)] = [
        ("virtio", "virtio"), ("e1000e", "e1000e"), ("e1000", "e1000"), ("igb", "igb"), ("rtl8139", "rtl8139"),
        ("vmxnet3", "vmxnet3"), ("ne2k_pci", "ne2k_pci"), ("pcnet", "pcnet"), ("usb-net", "usb-net"),
    ]
    static let macvtapMode: [(String, String)] = [("bridge", "Bridge"), ("vepa", "VEPA"), ("private", "Private"), ("passthrough", "Passthrough")]
    static let graphicsType: [(String, String)] = [("vnc", "VNC server"), ("spice", "Spice server")]
    static let keymap: [(String, String)] = [("", "Auto")] + [
        "ar", "da", "de", "de-ch", "en-gb", "en-us", "es", "et", "fi", "fo", "fr", "fr-be", "fr-ca", "fr-ch", "hr", "hu",
        "is", "it", "ja", "lt", "lv", "mk", "nl", "nl-be", "no", "pl", "pt", "pt-br", "ru", "sl", "sv", "th", "tr",
    ].map { ($0, $0) }
    static let soundModel: [(String, String)] = [
        ("ich9", "ich9"), ("ich6", "ich6"), ("ich7", "ich7"), ("ac97", "ac97"), ("es1370", "es1370"), ("sb16", "sb16"),
        ("usb", "usb"), ("pcspk", "pcspk"), ("virtio", "virtio"),
    ]
    static let charType: [(String, String)] = [
        ("pty", "Pseudo TTY (pty)"), ("dev", "Physical host device (dev)"), ("file", "Output to a file (file)"),
        ("pipe", "Named pipe (pipe)"), ("tcp", "TCP net console (tcp)"), ("udp", "UDP net console (udp)"),
        ("unix", "UNIX socket (unix)"), ("spicevmc", "Spice agent (spicevmc)"), ("spiceport", "Spice port (spiceport)"),
        ("qemu-vdagent", "QEMU vdagent (qemu-vdagent)"), ("null", "Null device (null)"),
    ]
    static let serialTarget: [(String, String)] = [
        ("", "Default"), ("isa-serial", "ISA serial"), ("pci-serial", "PCI serial"), ("usb-serial", "USB serial"),
        ("system-serial", "System serial (ARM)"), ("spapr-vio-serial", "sPAPR VIO"),
    ]
    static let consoleTarget: [(String, String)] = [("serial", "Serial"), ("virtio", "VirtIO")]
    static let channelNames: [(String, String)] = [
        ("org.qemu.guest_agent.0", "org.qemu.guest_agent.0 (QEMU guest agent)"),
        ("com.redhat.spice.0", "com.redhat.spice.0 (Spice agent)"),
        ("org.libguestfs.channel.0", "org.libguestfs.channel.0"),
        ("org.spice-space.webdav.0", "org.spice-space.webdav.0 (Spice WebDAV)"),
    ]
    static let videoModel: [(String, String)] = [
        ("virtio", "Virtio"), ("qxl", "QXL"), ("vga", "VGA"), ("bochs", "Bochs"), ("ramfb", "Ramfb"),
        ("cirrus", "Cirrus"), ("vmvga", "VMVGA"), ("none", "None"),
    ]
    static let watchdogModel: [(String, String)] = [
        ("i6300esb", "i6300esb"), ("ib700", "ib700"), ("itco", "itco"), ("diag288", "diag288"),
    ]
    static let watchdogAction: [(String, String)] = [
        ("reset", "Forcefully reset the guest"), ("shutdown", "Gracefully shutdown the guest"),
        ("poweroff", "Forcefully power off the guest"), ("pause", "Pause the guest"), ("none", "No action"),
        ("dump", "Dump guest memory core"), ("inject-nmi", "Inject NMI"),
    ]
    static let usbModel: [(String, String)] = [
        ("", "Hypervisor default"), ("qemu-xhci", "USB 3 (qemu-xhci)"), ("nec-xhci", "USB 3 (nec-xhci)"),
        ("ich9-ehci1", "USB 2 (ich9-ehci1)"), ("piix3-uhci", "USB 1 (piix3-uhci)"), ("piix4-uhci", "USB 1 (piix4-uhci)"),
        ("none", "None"),
    ]
    static let scsiModel: [(String, String)] = [
        ("", "Hypervisor default"), ("virtio-scsi", "VirtIO SCSI"), ("lsilogic", "lsilogic"), ("lsisas1068", "lsisas1068"),
        ("lsisas1078", "lsisas1078"), ("megasas", "megasas"), ("ibmvscsi", "ibmvscsi"),
    ]
    static let controllerType: [(String, String)] = [
        ("scsi", "SCSI"), ("nvme", "NVMe"), ("usb", "USB"), ("virtio-serial", "VirtIO Serial"), ("sata", "SATA"),
        ("ccid", "CCID"), ("ide", "IDE"), ("pci", "PCI"),
    ]
    static let fsDriver: [(String, String)] = [("virtiofs", "virtiofs"), ("path", "virtio-9p")]
    static let fsAccess: [(String, String)] = [("passthrough", "Passthrough"), ("mapped", "Mapped"), ("squash", "Squash")]
    static let tpmModel: [(String, String)] = [("tpm-crb", "CRB"), ("tpm-tis", "TIS"), ("tpm-spapr", "sPAPR")]
    static let tpmBackend: [(String, String)] = [("emulator", "Emulated"), ("passthrough", "Passthrough"), ("external", "External")]
    static let tpmVersion: [(String, String)] = [("2.0", "2.0"), ("1.2", "1.2")]
    static let rngBackend: [(String, String)] = [("random", "Random"), ("egd", "Entropy Gathering Daemon"), ("builtin", "Builtin RNG")]
    static let rngDevice: [(String, String)] = [("/dev/urandom", "/dev/urandom"), ("/dev/random", "/dev/random"), ("/dev/hwrng", "/dev/hwrng")]
    static let panicModel: [(String, String)] = [
        ("isa", "ISA"), ("pvpanic", "pvpanic"), ("hyperv", "Hyper-V"), ("pseries", "pSeries"), ("s390", "s390"),
    ]
    static let smartcardMode: [(String, String)] = [("passthrough", "Passthrough"), ("host", "Host")]
    static let inputType: [(String, String)] = [("tablet", "EvTouch USB Graphics Tablet"), ("mouse", "Generic Mouse"), ("keyboard", "Generic Keyboard")]
    static let inputBus: [(String, String)] = [("usb", "USB"), ("virtio", "VirtIO"), ("ps2", "PS/2")]
}

/// Routes a hardware item to its page.
struct HardwarePage: View {
    let editor: DomainEditor
    let item: HardwareItem

    var body: some View {
        switch item.kind {
        case .overview: OverviewPage(editor: editor)
        case .osInfo: OSInfoPage(editor: editor)
        case .performance: PerformancePage(editor: editor)
        case .cpus: CPUsPage(editor: editor)
        case .memory: MemoryPage(editor: editor)
        case .boot: BootPage(editor: editor)
        default:
            if let el = item.element { DeviceDetails(editor: editor, title: item.label, kind: item.kind, el: el) }
        }
    }
}

struct DeviceDetails: View {
    let editor: DomainEditor
    let title: String
    let kind: HardwareKind
    let el: XMLElement

    var body: some View {
        DevicePage(editor: editor, title: title, element: el) {
            switch kind {
            case .disk: DiskFields(editor: editor, el: el)
            case .nic: NICFields(editor: editor, el: el)
            case .input: InputFields(editor: editor, el: el)
            case .graphics: GraphicsFields(editor: editor, el: el)
            case .sound: Choice("Model", editor.attr(el, "model"), Options.soundModel)
            case .char: CharFields(editor: editor, el: el)
            case .video: VideoFields(editor: editor, el: el)
            case .watchdog:
                Choice("Model", editor.attr(el, "model"), Options.watchdogModel)
                Choice("Action", editor.attr(el, "action", default: "reset"), Options.watchdogAction)
            case .controller: ControllerFields(editor: editor, el: el)
            case .filesystem: FilesystemFields(editor: editor, el: el)
            case .smartcard: Choice("Mode", editor.attr(el, "mode"), Options.smartcardMode)
            case .tpm: TPMFields(editor: editor, el: el)
            case .rng: RNGFields(editor: editor, el: el)
            case .panic: Choice("Model", editor.attr(el, "model"), Options.panicModel)
            case .vsock: VSockFields(editor: editor, el: el)
            case .hostdev: HostdevFields(el: el)
            case .redirdev:
                ReadOnly("Type", Pretty.charType(el.attr("type") ?? ""))
                ReadOnly("Bus", Pretty.bus(el.attr("bus") ?? ""))
            default: EmptyView()
            }
        }
    }
}

// MARK: Disk

struct DiskFields: View {
    let editor: DomainEditor
    let el: XMLElement
    @StateVar private var chooser = false
    @StateVar private var volumeInfo: String?

    private var isCDROM: Bool { ["cdrom", "floppy"].contains(el.attr("device") ?? "") }
    private var source: XMLElement? { el.child("source") }
    private var sourcePath: String {
        _ = editor.revision
        return source?.attr("file") ?? source?.attr("dev") ?? source.map { s in
            [s.attr("pool"), s.attr("volume")].compactMap { $0 }.joined(separator: "/")
        } ?? source?.attr("name") ?? ""
    }

    var body: some View {
        let target = el.child("target"), driver = el.child("driver")
        Section {
            LabeledContent("Source path") {
                HStack {
                    Text(sourcePath.isEmpty ? (isCDROM ? "No media" : "—") : sourcePath)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    if isCDROM && !sourcePath.isEmpty {
                        Button("Disconnect") { setSource(nil) }
                    }
                    Button(isCDROM && sourcePath.isEmpty ? "Connect…" : "Browse…") { chooser = true }
                }
            }
            if let volumeInfo { ReadOnly("Storage size", volumeInfo) }
            ReadOnly("Device type", (el.attr("device") ?? "disk").capitalized)
            ReadOnly("Target device", target?.attr("dev") ?? "")
        }
        Section("Advanced options") {
            Choice("Disk bus", editor.attr(target, "bus"), Options.diskBus)
            Toggle("Read-only", isOn: editor.flag(el, "readonly")).disabled(isCDROM)
            Toggle("Shareable", isOn: editor.flag(el, "shareable"))
            if ["usb", "scsi"].contains(target?.attr("bus") ?? "") {
                Toggle("Removable", isOn: Binding(
                    get: { _ = editor.revision; return target?.attr("removable") == "on" },
                    set: { editor.attr(target, "removable").wrappedValue = $0 ? "on" : "" }))
            }
            Field("Serial number", editor.text(el, "serial"))
            Choice("Disk format", editor.attr(driver, "type", default: "raw"), Options.diskFormat)
        }
        Section("Performance options") {
            Choice("Cache mode", editor.attr(driver, "cache"), Options.cache)
            Choice("Discard mode", editor.attr(driver, "discard"), Options.discard)
            Choice("Detect zeroes", editor.attr(driver, "detect_zeroes"), Options.detectZeroes)
            Choice("IO mode", editor.attr(driver, "io"), Options.io)
        }
        .sheet(isPresented: $chooser) {
            StorageBrowser(connection: editor.connection, purpose: isCDROM ? .media : .disk) { path in
                setSource(path)
            }
        }
        .task(id: sourcePath) { await loadVolumeInfo() }
    }

    private func setSource(_ path: String?) {
        el.removeChildren(named: "source")
        if let path {
            let s = XMLElement(name: "source")
            // Block devices use dev=, everything else file=.
            if path.hasPrefix("/dev/") {
                el.setAttr("type", "block")
                s.setAttr("dev", path)
            } else {
                el.setAttr("type", "file")
                s.setAttr("file", path)
            }
            el.insertChild(s, at: min(1, el.childCount))
        }
        if el.child("driver") == nil {
            let d = XMLElement(name: "driver")
            d.setAttr("name", "qemu")
            d.setAttr("type", path?.hasSuffix(".qcow2") == true ? "qcow2" : "raw")
            el.insertChild(d, at: 0)
        }
        editor.touch(el, hot: isCDROM)
    }

    private func loadVolumeInfo() async {
        let path = sourcePath
        guard !path.isEmpty else { volumeInfo = nil; return }
        volumeInfo = try? await editor.connection.withConnection { conn in
            let info = try conn.volume(path: path).info()
            return "\(Pretty.gib(info.capacity)) (\(Pretty.gib(info.allocation)) allocated)"
        }
    }
}

// MARK: NIC

struct NICFields: View {
    let editor: DomainEditor
    let el: XMLElement
    @StateVar private var networks: [String] = []

    var body: some View {
        let source = el.child("source"), model = el.child("model"), link = el.child("link")
        Section {
            Picker("Network source", selection: typeBinding()) {
                Text("Virtual network").tag("network")
                Text("Bridge device").tag("bridge")
                Text("Macvtap device").tag("direct")
                Text("Usermode networking").tag("user")
                if !["network", "bridge", "direct", "user"].contains(el.attr("type") ?? "") {
                    Text(el.attr("type") ?? "").tag(el.attr("type") ?? "")
                }
            }
            switch el.attr("type") {
            case "network":
                Picker("Network", selection: editor.attr(source, "network")) {
                    ForEach(networks.contains(source?.attr("network") ?? "") ? networks : networks + [source?.attr("network") ?? ""], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                if let pg = source?.attr("portgroup") { ReadOnly("Portgroup", pg) }
            case "bridge":
                Field("Bridge name", editor.attr(source, "bridge"), prompt: "br0")
            case "direct":
                Field("Device name", editor.attr(source, "dev"), prompt: "eth0")
                Choice("Source mode", editor.attr(source, "mode", default: "vepa"), Options.macvtapMode)
            default: EmptyView()
            }
            Choice("Device model", editor.attr(model, "type"), Options.nicModel)
            Field("MAC address", editor.attr(el.child("mac"), "address"))
            Toggle("Link state: active", isOn: Binding(
                get: { _ = editor.revision; return link?.attr("state") != "down" },
                set: { up in
                    let l = el.ensure("link")
                    l.setAttr("state", up ? "up" : "down")
                    editor.touch(el, hot: true)
                }))
        }
        .task { networks = (try? await editor.connection.withConnection { try $0.networks().map(\.name) }) ?? [] }
    }

    private func typeBinding() -> Binding<String> {
        Binding(
            get: { _ = editor.revision; return el.attr("type") ?? "network" },
            set: { t in
                el.setAttr("type", t)
                el.removeChildren(named: "source")
                if t != "user" {
                    let s = XMLElement(name: "source")
                    switch t {
                    case "network": s.setAttr("network", networks.first ?? "default")
                    case "bridge": s.setAttr("bridge", "br0")
                    case "direct": s.setAttr("dev", "eth0"); s.setAttr("mode", "bridge")
                    default: break
                    }
                    el.insertChild(s, at: min(1, el.childCount))
                }
                editor.touch(el)
            })
    }
}

// MARK: Input / Graphics / Video

struct InputFields: View {
    let editor: DomainEditor
    let el: XMLElement
    var editable = false

    var body: some View {
        if editable {
            Choice("Type", editor.attr(el, "type"), Options.inputType)
            Choice("Bus", editor.attr(el, "bus"), Options.inputBus)
        } else {
            ReadOnly("Type", Options.inputType.first { $0.0 == el.attr("type") }?.1 ?? (el.attr("type") ?? ""))
            ReadOnly("Mode", el.attr("type") == "tablet" ? "Absolute movement" : "Relative movement")
            ReadOnly("Bus", Pretty.bus(el.attr("bus") ?? ""))
        }
    }
}

struct GraphicsFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        let listen = el.child("listen")
        Section {
            Choice("Type", editor.attr(el, "type"), Options.graphicsType)
            Picker("Listen type", selection: listenTypeBinding()) {
                Text("Address").tag("address")
                Text("None").tag("none")
                Text("Socket").tag("socket")
            }
            if (listen?.attr("type") ?? "address") == "address" {
                Picker("Address", selection: addressBinding()) {
                    Text("Localhost only").tag("127.0.0.1")
                    Text("All interfaces").tag("0.0.0.0")
                    Text("Hypervisor default").tag("")
                    let cur = el.attr("listen") ?? ""
                    if !["127.0.0.1", "0.0.0.0", ""].contains(cur) { Text(cur).tag(cur) }
                }
                Toggle("Automatic port", isOn: Binding(
                    get: { _ = editor.revision; return el.attr("autoport") != "no" },
                    set: { auto in
                        el.setAttr("autoport", auto ? "yes" : "no")
                        el.setAttr("port", auto ? "-1" : (el.attr("type") == "spice" ? "5900" : "5900"))
                        editor.touch(el)
                    }))
                if el.attr("autoport") == "no" {
                    NumberField(title: "Port", value: editor.number(editor.attr(el, "port"), default: 5900), range: 5900 ... 65535)
                }
            }
            Toggle("Password", isOn: Binding(
                get: { _ = editor.revision; return el.attribute(forName: "passwd") != nil },
                set: { on in
                    if on { el.setAttr("passwd", "") } else { el.removeAttribute(forName: "passwd") }
                    editor.touch(el)
                }))
            if el.attribute(forName: "passwd") != nil {
                SecureField("Password", text: editor.attr(el, "passwd"))
            }
            if el.attr("type") == "vnc" {
                Choice("Keymap", editor.attr(el, "keymap"), Options.keymap)
            }
            if el.attr("type") == "spice" {
                Toggle("OpenGL", isOn: Binding(
                    get: { _ = editor.revision; return el.child("gl")?.attr("enable") == "yes" },
                    set: { on in
                        if on { el.ensure("gl").setAttr("enable", "yes") } else { el.removeChildren(named: "gl") }
                        editor.touch(el)
                    }))
                if el.child("gl") != nil {
                    Field("Render node", editor.attr(el.child("gl"), "rendernode"), prompt: "Auto")
                }
            }
        }
    }

    private func listenTypeBinding() -> Binding<String> {
        Binding(
            get: { _ = editor.revision; return el.child("listen")?.attr("type") ?? "address" },
            set: { t in
                el.removeChildren(named: "listen")
                let l = XMLElement(name: "listen")
                l.setAttr("type", t)
                if t == "address" { l.setAttr("address", "127.0.0.1"); el.setAttr("listen", "127.0.0.1") }
                else { el.removeAttribute(forName: "listen") }
                el.addChild(l)
                editor.touch(el)
            })
    }

    private func addressBinding() -> Binding<String> {
        Binding(
            get: { _ = editor.revision; return el.attr("listen") ?? el.child("listen")?.attr("address") ?? "" },
            set: { a in
                if a.isEmpty { el.removeAttribute(forName: "listen") } else { el.setAttr("listen", a) }
                if let l = el.child("listen") {
                    if a.isEmpty { l.removeAttribute(forName: "address") } else { l.setAttr("address", a) }
                }
                editor.touch(el)
            })
    }
}

struct VideoFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        let model = el.ensure("model")
        Choice("Model", editor.attr(model, "type"), Options.videoModel)
        if model.attr("type") == "virtio" {
            Toggle("3D acceleration", isOn: Binding(
                get: { _ = editor.revision; return model.child("acceleration")?.attr("accel3d") == "yes" },
                set: { on in
                    if on { model.ensure("acceleration").setAttr("accel3d", "yes") } else { model.removeChildren(named: "acceleration") }
                    editor.touch(el)
                }))
        }
        NumberField(title: "Heads", value: editor.number(editor.attr(model, "heads"), default: 1), range: 1 ... 4)
        if ["qxl", "vga", "vmvga", "cirrus", "bochs"].contains(model.attr("type") ?? "") {
            NumberField(title: "VRAM", value: editor.number(editor.attr(model, "vram"), default: 16384), range: 1024 ... 1_048_576, unit: "KiB")
        }
    }
}

// MARK: Character devices

struct CharFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        let source = el.child("source"), target = el.child("target"), type = el.attr("type") ?? "pty"
        Section {
            Choice("Device type", editor.attr(el, "type"), Options.charType)
            switch type {
            case "pty":
                if let path = source?.attr("path") { ReadOnly("Source path", path) }
                else { ReadOnly("Source path", "Allocated when the VM starts") }
            case "dev", "file", "pipe":
                Field("Path", editor.attr(el.ensure("source"), "path"))
            case "unix":
                Field("Path", editor.attr(el.ensure("source"), "path"), prompt: "Automatic")
                Choice("Mode", editor.attr(el.ensure("source"), "mode", default: "bind"), [("bind", "Server (bind)"), ("connect", "Client (connect)")])
            case "tcp", "udp":
                Field("Host", editor.attr(el.ensure("source"), "host"), prompt: "127.0.0.1")
                Field("Port", editor.attr(el.ensure("source"), "service"), prompt: "4555")
                if type == "tcp" {
                    Choice("Mode", editor.attr(el.ensure("source"), "mode", default: "bind"), [("bind", "Server (bind)"), ("connect", "Client (connect)")])
                    Choice("Protocol", editor.attr(el.ensure("protocol"), "type", default: "raw"), [("raw", "Raw"), ("telnet", "Telnet")])
                }
            default: EmptyView()
            }
        }
        Section {
            switch el.name {
            case "serial":
                Choice("Target type", editor.attr(target, "type"), Options.serialTarget)
                ReadOnly("Port", target?.attr("port") ?? "0")
            case "console":
                Choice("Target type", editor.attr(target, "type", default: "serial"), Options.consoleTarget)
            case "channel":
                Picker("Target name", selection: editor.attr(target, "name")) {
                    ForEach(channelOptions(target?.attr("name") ?? ""), id: \.0) { Text($0.1).tag($0.0) }
                }
            default:
                ReadOnly("Port", target?.attr("port") ?? "0")
            }
            if el.name != "channel" {
                Field("Log file", editor.attr(el.child("log") ?? logElement(), "file"), prompt: "None")
            }
        }
    }

    private func channelOptions(_ current: String) -> [(String, String)] {
        Options.channelNames.contains { $0.0 == current } || current.isEmpty
            ? Options.channelNames : Options.channelNames + [(current, current)]
    }

    private func logElement() -> XMLElement {
        // Detached placeholder; attached on first edit.
        let l = XMLElement(name: "log")
        el.addChild(l)
        return l
    }
}

// MARK: Controller, filesystem, TPM, RNG, VSOCK, hostdev

struct ControllerFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        let type = el.attr("type") ?? ""
        Section {
            ReadOnly("Type", Pretty.controllerType(type))
            switch type {
            case "usb": Choice("Model", editor.attr(el, "model"), Options.usbModel)
            case "scsi": Choice("Model", editor.attr(el, "model"), Options.scsiModel)
            default: ReadOnly("Model", el.attr("model") ?? "Hypervisor default")
            }
            ReadOnly("Index", el.attr("index") ?? "0")
        }
        let attached = attachedDevices(type: type)
        if !attached.isEmpty {
            Section("Devices") {
                ForEach(attached, id: \.self) { Text($0) }
            }
        }
    }

    private func attachedDevices(type: String) -> [String] {
        guard ["scsi", "sata", "usb", "ide", "virtio-serial", "nvme"].contains(type) else { return [] }
        let index = el.attr("index") ?? "0"
        return editor.hardwareItems.compactMap { item in
            guard let d = item.element, let addr = d.child("address") else { return nil }
            let addrType = addr.attr("type") ?? ""
            let matches = (addrType == "drive" && ["scsi", "sata", "ide"].contains(type))
                || (addrType == "usb" && type == "usb")
                || (addrType == "virtio-serial" && type == "virtio-serial")
            guard matches, (addr.attr("controller") ?? addr.attr("bus") ?? "0") == index else { return nil }
            if addrType == "drive", d.child("target")?.attr("bus") != type { return nil }
            return item.label
        }
    }
}

struct FilesystemFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        let driver = el.ensure("driver")
        Choice("Driver", editor.attr(driver, "type", default: "path"), Options.fsDriver)
        if driver.attr("type") != "virtiofs" {
            Choice("Mode", editor.attr(el, "accessmode", default: "passthrough"), Options.fsAccess)
        }
        Field("Source path", editor.attr(el.ensure("source"), "dir"), prompt: "/srv/share")
        Field("Target path", editor.attr(el.ensure("target"), "dir"), prompt: "mount_tag")
        Toggle("Export filesystem as readonly mount", isOn: editor.flag(el, "readonly"))
        if driver.attr("type") == "virtiofs", editor.root?.child("memoryBacking")?.child("access")?.attr("mode") != "shared" {
            Label("virtiofs requires shared memory (Memory page).", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

struct TPMFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        let backend = el.ensure("backend")
        Choice("Model", editor.attr(el, "model", default: "tpm-crb"), Options.tpmModel)
        Choice("Backend", editor.attr(backend, "type", default: "emulator"), Options.tpmBackend)
        if backend.attr("type") == "emulator" || backend.attr("type") == nil {
            Choice("Version", editor.attr(backend, "version", default: "2.0"), Options.tpmVersion)
        }
        if backend.attr("type") == "passthrough" {
            Field("Device path", editor.attr(backend.ensure("device"), "path"), prompt: "/dev/tpm0")
        }
    }
}

struct RNGFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        let backend = el.ensure("backend")
        Choice("Backend", editor.attr(backend, "model", default: "random"), Options.rngBackend)
        switch backend.attr("model") {
        case "random", nil:
            Picker("Host device", selection: Binding(
                get: { _ = editor.revision; return backend.stringValue ?? "/dev/urandom" },
                set: { backend.stringValue = $0; editor.touch(el) })) {
                ForEach(Options.rngDevice, id: \.0) { Text($0.1).tag($0.0) }
            }
        case "egd":
            let src = backend.child("source") ?? { let s = XMLElement(name: "source"); s.setAttr("mode", "connect"); backend.addChild(s); return s }()
            Choice("Type", editor.attr(backend, "type", default: "tcp"), [("tcp", "TCP"), ("udp", "UDP")])
            Field("Host", editor.attr(src, "host"))
            Field("Port", editor.attr(src, "service"))
        default: EmptyView()
        }
        Field("Rate (bytes)", Binding(
            get: { _ = editor.revision; return el.child("rate")?.attr("bytes") ?? "" },
            set: { v in
                if v.isEmpty { el.removeChildren(named: "rate") } else { el.ensure("rate").setAttr("bytes", v) }
                editor.touch(el)
            }), prompt: "Unlimited")
    }
}

struct VSockFields: View {
    let editor: DomainEditor
    let el: XMLElement

    var body: some View {
        let cid = el.ensure("cid")
        Toggle("Automatic CID", isOn: Binding(
            get: { _ = editor.revision; return cid.attr("auto") != "no" },
            set: { on in
                cid.setAttr("auto", on ? "yes" : "no")
                if on { cid.removeAttribute(forName: "address") } else { cid.setAttr("address", "3") }
                editor.touch(el)
            }))
        if cid.attr("auto") == "no" {
            NumberField(title: "Guest CID", value: editor.number(editor.attr(cid, "address"), default: 3), range: 3 ... 4_294_967_294)
        }
    }
}

struct HostdevFields: View {
    let el: XMLElement

    var body: some View {
        let src = el.child("source")
        ReadOnly("Type", (el.attr("type") ?? "").uppercased())
        if let v = src?.child("vendor")?.attr("id") { ReadOnly("Vendor", v) }
        if let p = src?.child("product")?.attr("id") { ReadOnly("Product", p) }
        if let a = src?.child("address") {
            ReadOnly("Address", (a.attributes ?? []).map { "\($0.name ?? "")=\($0.stringValue ?? "")" }.joined(separator: " "))
        }
        ReadOnly("Managed", el.attr("managed") ?? "no")
    }
}
