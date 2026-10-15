// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct NewVMSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let initial: ConnectionModel?

    @StateVar private var connectionID: UUID?
    @StateVar private var caps: HostCapabilities?
    @StateVar private var pools: [String] = []

    @StateVar private var name = "vm1"
    @StateVar private var arch = ""
    @StateVar private var memoryGiB = 4
    @StateVar private var vcpus = 2
    @StateVar private var diskGiB = 32
    @StateVar private var isoPath = ""
    @StateVar private var pool = "default"
    @StateVar private var network = "default"
    @StateVar private var startAfter = true
    @StateVar private var showISOPicker = false
    @StateVar private var busy = false
    @StateVar private var error: String?

    private var connection: ConnectionModel? { connectionID.flatMap(app.connection) }
    private var isLocal: Bool { connection?.isLocal ?? false }
    private var connected: [ConnectionModel] { app.connections.filter { $0.status == .connected } }

    private var archChoices: [String] {
        if isLocal { return ["aarch64", "x86_64"] }
        let guests = caps?.guests ?? []
        let kvm = guests.filter { $0.domainTypes.contains("kvm") }.map(\.arch)
        return kvm.isEmpty ? guests.map(\.arch) : kvm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Connection", selection: $connectionID) {
                        ForEach(connected) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("Name", text: $name)
                }
                Section("Installation") {
                    if isLocal {
                        LabeledContent("ISO image") {
                            HStack {
                                Text(isoPath.isEmpty ? "None" : (isoPath as NSString).lastPathComponent)
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { showISOPicker = true }
                            }
                        }
                    } else {
                        TextField("ISO path on host", text: $isoPath, prompt: Text("/var/lib/libvirt/images/ubuntu.iso"))
                    }
                    Picker("Architecture", selection: $arch) {
                        ForEach(archChoices, id: \.self) { a in Text(archLabel(a)).tag(a) }
                    }
                }
                Section("Resources") {
                    Stepper("Memory: \(memoryGiB) GiB", value: $memoryGiB, in: 1 ... 256)
                    Stepper("vCPUs: \(vcpus)", value: $vcpus, in: 1 ... 64)
                    Stepper("Disk: \(diskGiB) GiB", value: $diskGiB, in: 1 ... 4096, step: 8)
                    if !isLocal {
                        Picker("Storage pool", selection: $pool) {
                            ForEach(pools, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Network", text: $network)
                    }
                }
                Toggle("Start VM and open console", isOn: $startAfter)
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || connection == nil || name.isEmpty || arch.isEmpty)
            }
            .padding()
        }
        .frame(width: 500)
        .fileImporter(isPresented: $showISOPicker, allowedContentTypes: [.diskImage, UTType(filenameExtension: "iso") ?? .data]) { result in
            if case .success(let url) = result { isoPath = url.path }
        }
        .onAppear {
            connectionID = (initial?.status == .connected ? initial : connected.first)?.id
        }
        .task(id: connectionID) { await loadHost() }
    }

    private func archLabel(_ a: String) -> String {
        if isLocal { return a == "aarch64" ? "ARM64 (native, Hypervisor.framework)" : "x86_64 (emulated, slow)" }
        let kvm = caps?.guest(arch: a)?.domainTypes.contains("kvm") ?? false
        return kvm ? "\(a) (KVM)" : "\(a) (emulated)"
    }

    private func loadHost() async {
        guard let connection else { return }
        caps = nil
        if let xml = try? await connection.withConnection({ try $0.capabilities() }) {
            caps = HostCapabilities(xml: xml)
        }
        if !connection.isLocal {
            pools = (try? await connection.withConnection { try $0.storagePoolNames() }) ?? []
            if !pools.contains(pool) { pool = pools.first ?? "" }
        }
        let preferred = isLocal ? "aarch64" : (caps?.hostArch ?? "x86_64")
        arch = archChoices.contains(preferred) ? preferred : (archChoices.first ?? "")
        let existing = Set(connection.domains.map(\.name))
        var n = 1
        while existing.contains("vm\(n)") { n += 1 }
        if name.hasPrefix("vm") { name = "vm\(n)" }
    }

    private func create() {
        guard let connection else { return }
        busy = true
        error = nil
        let spec = (name: name.trimmingCharacters(in: .whitespaces), arch: arch, mem: memoryGiB * 1024, cpus: vcpus,
                    disk: diskGiB, iso: isoPath.isEmpty ? nil : isoPath, pool: pool, network: network)
        let local = isLocal
        let guest = caps?.guest(arch: arch)

        Task {
            do {
                var diskPath = ""
                var vm: VMSpec
                if local {
                    let url = BundledRuntime.imagesDir.appendingPathComponent("\(spec.name).qcow2")
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        throw LibvirtError(message: "A disk image named \(url.lastPathComponent) already exists.")
                    }
                    try await Task.detached { try BundledRuntime.createDiskImage(at: url, sizeGiB: spec.disk) }.value
                    diskPath = url.path
                    let isARM = spec.arch == "aarch64"
                    vm = VMSpec(
                        name: spec.name, arch: spec.arch, domainType: isARM ? "hvf" : "qemu",
                        emulator: BundledRuntime.qemuBinary(arch: spec.arch),
                        memoryMiB: spec.mem, vcpus: spec.cpus, diskPath: diskPath, isoPath: spec.iso,
                        networkXML: VMBuilder.userNetwork,
                        firmware: isARM ? (BundledRuntime.firmware("edk2-aarch64-code.fd"),
                                           BundledRuntime.firmware("edk2-arm-vars.fd")) : nil)
                } else {
                    diskPath = try await connection.withConnection {
                        try $0.createVolume(pool: spec.pool, name: "\(spec.name).qcow2", capacityGiB: spec.disk)
                    }
                    vm = VMSpec(
                        name: spec.name, arch: spec.arch,
                        domainType: guest?.domainTypes.contains("kvm") == true ? "kvm" : "qemu",
                        emulator: guest?.emulator ?? "/usr/bin/qemu-system-\(spec.arch)",
                        memoryMiB: spec.mem, vcpus: spec.cpus, diskPath: diskPath, isoPath: spec.iso,
                        networkXML: VMBuilder.libvirtNetwork(spec.network), firmware: nil)
                }

                let xml = VMBuilder.xml(for: vm)
                do {
                    try await connection.define(xml: xml)
                } catch {
                    let created = diskPath
                    if local { try? FileManager.default.removeItem(atPath: created) }
                    else { _ = try? await connection.withConnection { try $0.deleteVolume(path: created) } }
                    throw error
                }

                let uuid = try await connection.withConnection { conn in
                    try conn.allDomains().first { $0.name == spec.name }?.uuid ?? ""
                }
                if startAfter, !uuid.isEmpty {
                    try await connection.withConnection { try $0.domain(uuid: uuid).start() }
                    connection.refresh()
                    openWindow(id: "console", value: ConsoleTarget(connectionID: connection.id, domainUUID: uuid))
                }
                if !uuid.isEmpty { app.selection = .domain(connection.id, uuid) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
