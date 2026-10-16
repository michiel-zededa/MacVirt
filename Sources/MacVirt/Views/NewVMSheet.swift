// SPDX-License-Identifier: GPL-2.0-or-later
// New VM wizard (virt-manager's createvm): install method, OS, resources,
// storage, name/network, and "Customize configuration before install".

import SwiftUI
import UniformTypeIdentifiers

struct NewVMSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let initial: ConnectionModel?

    @StateVar private var step = 1
    @StateVar private var connectionID: UUID?
    @StateVar private var caps: HostCapabilities?
    @StateVar private var networks: [String] = []
    @StateVar private var defaultPoolFree: UInt64?

    @StateVar private var method: InstallMethod = .iso
    @StateVar private var arch = ""
    @StateVar private var virtType = ""
    @StateVar private var isoPath = ""
    @StateVar private var importPath = ""
    @StateVar private var os: OSProfile = OSProfile.all[0]
    @StateVar private var firmware: Firmware = .uefi
    @StateVar private var memoryMiB = 4096
    @StateVar private var vcpus = 2
    @StateVar private var enableStorage = true
    @StateVar private var createDisk = true
    @StateVar private var diskGiB = 20.0
    @StateVar private var customDiskPath = ""
    @StateVar private var name = "vm1"
    @StateVar private var netChoice = ""
    @StateVar private var bridgeName = "br0"
    @StateVar private var customize = false
    @StateVar private var browse: StorageBrowser.Purpose?
    @StateVar private var busy = false
    @StateVar private var error: String?

    private var connection: ConnectionModel? { connectionID.flatMap(app.connection) }
    private var isLocal: Bool { connection?.isLocal ?? false }
    private var connected: [ConnectionModel] { app.connections.filter { $0.status == .connected } }
    private var isARM: Bool { arch == "aarch64" }
    private var lastStep: Int { 5 }

    private var archChoices: [String] {
        if isLocal { return ["aarch64", "x86_64"] }
        let guests = caps?.guests ?? []
        let kvm = guests.filter { $0.domainTypes.contains("kvm") }.map(\.arch)
        return kvm.isEmpty ? guests.map(\.arch) : kvm + guests.map(\.arch).filter { !kvm.contains($0) }
    }

    private var virtTypes: [String] {
        if isLocal { return isARM ? ["hvf", "qemu"] : ["qemu"] }
        return caps?.guest(arch: arch)?.domainTypes ?? ["kvm"]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create a new virtual machine").font(.title3).bold()
                Spacer()
                Text("Step \(step) of \(lastStep)").foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top])
            Form {
                switch step {
                case 1: stepMethod
                case 2: stepSource
                case 3: stepResources
                case 4: stepStorage
                default: stepFinish
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Creating domain…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Back") { step = previous(step) }.disabled(step == 1 || busy)
                if step < lastStep {
                    Button("Forward") { forward() }.keyboardShortcut(.defaultAction).disabled(connection == nil)
                } else {
                    Button("Finish") { create() }.keyboardShortcut(.defaultAction).disabled(busy || name.isEmpty)
                }
            }
            .padding()
        }
        .frame(width: 580, height: 600)
        .onAppear { connectionID = (initial?.status == .connected ? initial : connected.first)?.id }
        .task(id: connectionID) { await loadHost() }
        .sheet(item: $browse) { purpose in
            if let connection {
                StorageBrowser(connection: connection, purpose: purpose) { path in
                    switch purpose {
                    case .media: isoPath = path
                    case .disk: if method == .importDisk { importPath = path } else { customDiskPath = path }
                    case .directory: break
                    }
                }
            }
        }
    }

    // MARK: Steps

    @ViewBuilder private var stepMethod: some View {
        Section {
            Picker("Connection", selection: $connectionID) {
                ForEach(connected) { Text($0.name).tag(Optional($0.id)) }
            }
        }
        Section("Choose how you would like to install the operating system") {
            Picker("", selection: $method) {
                ForEach(InstallMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        Section("Architecture options") {
            Picker("Architecture", selection: $arch) {
                ForEach(archChoices, id: \.self) { Text($0).tag($0) }
            }
            if virtTypes.count > 1 {
                Picker("Virt Type", selection: $virtType) {
                    ForEach(virtTypes, id: \.self) { Text(Self.prettyVirt($0)).tag($0) }
                }
            }
            if isLocal && arch == "x86_64" {
                Text("x86_64 guests are emulated on Apple Silicon and run much slower than ARM64 guests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var stepSource: some View {
        switch method {
        case .iso:
            Section("Choose ISO or CDROM install media") {
                HStack {
                    TextField("", text: $isoPath, prompt: Text(isLocal ? "Choose an ISO image" : "/var/lib/libvirt/images/install.iso")).labelsHidden()
                    Button("Browse…") { browse = .media }
                }
            }
        case .importDisk:
            Section("Provide the existing storage path") {
                HStack {
                    TextField("", text: $importPath, prompt: Text("/path/to/disk.qcow2")).labelsHidden()
                    Button("Browse…") { browse = .disk }
                }
            }
        case .pxe:
            Section { Text("The VM will boot from the network (PXE).").foregroundStyle(.secondary) }
        case .manual:
            Section { Text("The VM is created without installation media.").foregroundStyle(.secondary) }
        }
        Section("Choose the operating system you are installing") {
            Picker("Operating system", selection: $os) {
                ForEach(OSProfile.all) { Text($0.name).tag($0) }
            }
            .onChange(of: os) {
                memoryMiB = max(memoryMiB, os.minMemoryMiB)
                diskGiB = Double(os.defaultDiskGiB)
                if os.isWindows { firmware = .uefiSecure }
            }
            if !isARM {
                Picker("Firmware", selection: $firmware) {
                    ForEach(Firmware.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if os.isWindows {
                Text("Windows profiles add a TPM 2.0, Hyper-V enlightenments and SATA storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var stepResources: some View {
        Section("Choose Memory and CPU settings") {
            NumberField(title: "Memory", value: $memoryMiB, range: 256 ... 4_194_304, unit: "MiB")
            if let n = connection?.nodeInfo {
                Text("Up to \(n.memoryKiB / 1024) MiB available on the host").font(.caption).foregroundStyle(.secondary)
            }
            NumberField(title: "CPUs", value: $vcpus, range: 1 ... 512)
            if let n = connection?.nodeInfo {
                Text("Up to \(n.cpus) available").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var stepStorage: some View {
        Section {
            Toggle("Enable storage for this virtual machine", isOn: $enableStorage)
            if enableStorage {
                Picker("", selection: $createDisk) {
                    Text("Create a disk image for the virtual machine").tag(true)
                    Text("Select or create custom storage").tag(false)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if createDisk {
                    LabeledContent("Size") {
                        HStack {
                            TextField("", value: $diskGiB, format: .number.precision(.fractionLength(1))).frame(width: 80)
                            Stepper("", value: $diskGiB, in: 0.1 ... 1_000_000).labelsHidden()
                            Text("GiB")
                        }
                    }
                    if let free = defaultPoolFree {
                        Text("\(Pretty.gib(free)) available in the default location").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        TextField("", text: $customDiskPath, prompt: Text("/path/to/disk.qcow2")).labelsHidden()
                        Button("Manage…") { browse = .disk }
                    }
                }
            }
        }
    }

    @ViewBuilder private var stepFinish: some View {
        Section("Ready to begin the installation") {
            TextField("Name", text: $name)
            LabeledContent("OS", value: os.name)
            LabeledContent("Install", value: method.rawValue)
            LabeledContent("Memory", value: "\(memoryMiB) MiB")
            LabeledContent("CPUs", value: "\(vcpus)")
            LabeledContent("Storage", value: !enableStorage || method == .importDisk ? (method == .importDisk ? importPath : "None")
                           : createDisk ? String(format: "%.1f GiB in the default pool", diskGiB) : customDiskPath)
            Toggle("Customize configuration before install", isOn: $customize)
        }
        Section("Network selection") {
            Picker("Network", selection: $netChoice) {
                ForEach(networks, id: \.self) { Text("Virtual network '\($0)'").tag("network:\($0)") }
                if !isLocal { Text("Bridge device…").tag("bridge") }
                Text("Usermode networking").tag("user")
            }
            if netChoice == "bridge" { TextField("Device name", text: $bridgeName) }
        }
    }

    // MARK: Logic

    static func prettyVirt(_ t: String) -> String {
        ["kvm": "KVM", "qemu": "QEMU TCG", "hvf": "Hypervisor.framework"][t] ?? t
    }

    private func previous(_ s: Int) -> Int {
        s == 5 && method == .importDisk ? 3 : s - 1
    }

    private func forward() {
        error = nil
        if step == 2 {
            if method == .iso && isoPath.isEmpty { error = "An install media selection is required."; return }
            if method == .importDisk && importPath.isEmpty { error = "A storage path to import is required."; return }
        }
        if step == 3 && method == .importDisk { step = 5; return }
        if step == 4 && enableStorage && !createDisk && customDiskPath.isEmpty { error = "A storage path must be specified."; return }
        step += 1
    }

    private func loadHost() async {
        guard let connection else { return }
        caps = nil
        if let xml = try? await connection.withConnection({ try $0.capabilities() }) {
            caps = HostCapabilities(xml: xml)
        }
        let info = try? await connection.withConnection { conn -> ([String], UInt64?) in
            let nets = ((try? conn.networks()) ?? []).filter(\.isActive).map(\.name)
            let free = try? conn.storagePool(named: "default").info().available
            return (nets, free)
        }
        networks = info?.0 ?? []
        defaultPoolFree = info?.1
        netChoice = networks.contains("default") ? "network:default" : (networks.first.map { "network:\($0)" } ?? (isLocal ? "user" : "bridge"))
        let preferred = isLocal ? "aarch64" : (caps?.hostArch ?? "x86_64")
        arch = archChoices.contains(preferred) ? preferred : (archChoices.first ?? "")
        virtType = virtTypes.first ?? "kvm"
        let existing = Set(connection.domains.map(\.name))
        var n = 1
        while existing.contains("vm\(n)") { n += 1 }
        if name.hasPrefix("vm") { name = "vm\(n)" }
    }

    private func create() {
        guard let connection else { return }
        busy = true
        error = nil
        let existingNames = Set(connection.domains.map(\.name))
        guard !existingNames.contains(name) else {
            error = "Name '\(name)' is already in use by another virtual machine."
            busy = false
            return
        }
        let local = isLocal
        let guest = caps?.guest(arch: arch)
        let vmName = name.trimmingCharacters(in: .whitespaces)
        let wantsDisk = method == .importDisk || enableStorage
        let createNew = method != .importDisk && enableStorage && createDisk
        let size = diskGiB
        let format = Preferences.shared.defaultStorageFormat
        let existingPath = method == .importDisk ? importPath : customDiskPath
        let isARM = self.isARM
        let nicModel = os.isWindows && !isARM ? "e1000e" : "virtio"
        let net: String = switch netChoice {
        case let c where c.hasPrefix("network:"): VMBuilder.libvirtNetwork(String(c.dropFirst(8)), model: nicModel)
        case "bridge": VMBuilder.bridgeNetwork(bridgeName, model: nicModel)
        default: VMBuilder.userNetwork
        }

        Task {
            var createdVolume: String?
            do {
                var diskPath: String?
                if createNew {
                    diskPath = try await connection.withConnection { conn in
                        let pool = try conn.storagePool(named: "default")
                        if !pool.isActive { try pool.start() }
                        let ext = format == "raw" ? ".img" : ".qcow2"
                        let names = Set(((try? pool.volumes()) ?? []).map(\.name))
                        var file = vmName + ext, i = 1
                        while names.contains(file) { file = "\(vmName)-\(i)\(ext)"; i += 1 }
                        let cap = UInt64(size * 1_073_741_824)
                        let xml = VolumeXML.make(name: file, format: format, capacityBytes: cap, allocationBytes: format == "raw" ? cap : 0)
                        return try pool.createVolume(xml: xml).path
                    }
                    createdVolume = diskPath
                } else if wantsDisk {
                    diskPath = existingPath
                }
                let diskFormat = (diskPath.map { $0.hasSuffix(".qcow2") } ?? true) ? "qcow2" : "raw"

                var spec = VMSpec(
                    name: vmName, arch: arch, domainType: virtType, emulator: "",
                    memoryMiB: memoryMiB, vcpus: vcpus, diskPath: diskPath, diskFormat: createNew ? format : diskFormat,
                    isoPath: method == .iso ? isoPath : nil, pxe: method == .pxe, networkXML: net,
                    firmware: isARM ? .uefi : firmware, osID: os.libosinfo, windows: os.isWindows)
                if local {
                    spec.emulator = BundledRuntime.qemuBinary(arch: arch)
                    if isARM {
                        spec.firmwareFiles = (BundledRuntime.firmware("edk2-aarch64-code.qcow2"), BundledRuntime.firmware("edk2-arm-vars.qcow2"))
                    } else if firmware != .bios {
                        spec.firmwareFiles = (BundledRuntime.firmware("edk2-x86_64-code.qcow2"), BundledRuntime.firmware("edk2-i386-vars.qcow2"))
                    }
                } else {
                    spec.emulator = guest?.emulator ?? "/usr/bin/qemu-system-\(arch)"
                }

                let xml = VMBuilder.xml(for: spec)
                let start = !customize
                let uuid = try await connection.withConnection { conn in
                    let d = try conn.defineDomain(xml: xml)
                    if start { try d.start() }
                    return d.uuid
                }
                connection.refresh()
                app.selection = .domain(connection.id, uuid)
                openWindow(id: "vm", value: VMTarget(connectionID: connection.id, domainUUID: uuid, tab: customize ? .details : .console))
                dismiss()
            } catch {
                if let createdVolume {
                    _ = try? await connection.withConnection { try $0.deleteVolume(path: createdVolume) }
                }
                self.error = "Unable to complete install: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

extension StorageBrowser.Purpose: Identifiable {
    var id: Self { self }
}
