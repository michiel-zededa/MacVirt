// SPDX-License-Identifier: GPL-2.0-or-later
// Clone, Migrate and Delete dialogs.

import SwiftUI

// MARK: Clone

struct CloneDisk: Identifiable, Hashable {
    var id: String { target }
    var target: String
    var device: String
    var source: String
    var clone: Bool
    var reason: String?
    var newPath: String
}

struct CloneSheet: View {
    let connection: ConnectionModel
    let uuid: String
    @Environment(\.dismiss) private var dismiss

    @StateVar private var xml = ""
    @StateVar private var name = ""
    @StateVar private var disks: [CloneDisk] = []
    @StateVar private var error: String?
    @StateVar private var busy = false

    private var domain: DomainSummary? { connection.domain(uuid) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Clone virtual machine") {
                    LabeledContent("Original VM", value: domain?.name ?? "")
                    if !connection.isLocal { LabeledContent("Connection", value: connection.name) }
                    TextField("Name", text: $name).onChange(of: name) { recomputePaths() }
                }
                Section("Storage") {
                    ForEach($disks) { $d in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: d.device == "disk" ? "internaldrive" : d.device == "cdrom" ? "opticaldisc" : "opticaldiscdrive")
                                Text(d.source.isEmpty ? "No storage." : d.source).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Picker("", selection: $d.clone) {
                                    Text("Clone").tag(true)
                                    Text("Share").tag(false)
                                }
                                .labelsHidden()
                                .fixedSize()
                                .disabled(d.source.isEmpty || d.reason != nil && !d.clone)
                            }
                            if d.clone {
                                TextField("New path", text: $d.newPath).font(.caption)
                            } else {
                                Text("Share disk with \(domain?.name ?? "")\(d.reason.map { " (\($0))" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if disks.isEmpty { Text("No storage.").foregroundStyle(.secondary) }
                }
                Text("Cloning does not alter the guest OS contents. If you need to do things like change passwords or static IP addresses, please see the virt-sysprep(1) tool.")
                    .font(.caption).foregroundStyle(.secondary)
                if domain?.state.isActive == true {
                    Label("Domain to clone must be shutoff.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Creating virtual machine clone '\(name)'…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || name.isEmpty || domain?.state.isActive == true)
            }
            .padding()
        }
        .frame(width: 600, height: 520)
        .task { await load() }
    }

    private func load() async {
        guard let x = try? await connection.domainXML(uuid: uuid),
              let doc = try? XMLDocument(xmlString: x), let root = doc.rootElement() else { return }
        xml = x
        let orig = root.child("name")?.stringValue ?? "vm"
        let existing = Set(connection.domains.map(\.name))
        var base = orig, n = 0
        if let r = orig.range(of: #"-clone(\d*)$"#, options: .regularExpression) {
            base = String(orig[..<r.lowerBound])
            n = Int(orig[r].dropFirst(6)) ?? 0
            n += 1
        }
        var candidate = n == 0 ? "\(base)-clone" : "\(base)-clone\(n)"
        while existing.contains(candidate) { n += 1; candidate = "\(base)-clone\(n)" }
        name = candidate
        disks = root.all("devices/disk").compactMap { d in
            let src = d.child("source")?.attr("file") ?? d.child("source")?.attr("dev") ?? ""
            let device = d.attr("device") ?? "disk"
            var reason: String?
            if src.isEmpty { reason = "No storage to clone." }
            else if d.child("readonly") != nil || device != "disk" { reason = "Read Only" }
            else if d.child("shareable") != nil { reason = "Marked as shareable" }
            return CloneDisk(target: d.child("target")?.attr("dev") ?? UUID().uuidString, device: device,
                             source: src, clone: reason == nil, reason: reason, newPath: "")
        }
        recomputePaths()
    }

    private func recomputePaths() {
        let orig = domain?.name ?? ""
        for i in disks.indices where !disks[i].source.isEmpty {
            let url = URL(fileURLWithPath: disks[i].source)
            let ext = url.pathExtension.count <= 7 ? url.pathExtension : ""
            let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            let newStem = stem == orig ? name : "\(stem)-clone"
            disks[i].newPath = url.deletingLastPathComponent().appendingPathComponent(newStem + (ext.isEmpty ? "" : ".\(ext)")).path
        }
    }

    private func clone() {
        guard let doc = try? XMLDocument(xmlString: xml), let root = doc.rootElement() else { return }
        busy = true
        error = nil
        root.ensure("name").stringValue = name
        root.removeChildren(named: "uuid")
        root.removeChildren(named: "title")
        for mac in root.all("devices/interface/mac") { (mac.parent as? XMLElement)?.removeChild(at: mac.index) }
        for g in root.all("devices/graphics") where g.attr("autoport") == "no" {
            g.setAttr("autoport", "yes"); g.setAttr("port", "-1")
        }
        for c in root.all("devices/channel[@type='unix']/source") { c.removeAttribute(forName: "path") }
        if let nv = root.child("os")?.child("nvram") { nv.stringValue = nil; nv.removeAttribute(forName: "file") }
        var jobs: [(String, String)] = []
        for d in root.all("devices/disk") {
            let target = d.child("target")?.attr("dev") ?? ""
            guard let plan = disks.first(where: { $0.target == target }), plan.clone, let src = d.child("source") else { continue }
            if src.attribute(forName: "file") != nil { src.setAttr("file", plan.newPath) } else { src.setAttr("dev", plan.newPath) }
            jobs.append((plan.source, plan.newPath))
        }
        let newXML = doc.xmlString
        let cloneJobs = jobs
        let local = connection.isLocal
        Task {
            do {
                try await connection.withConnection { conn in
                    for (src, dst) in cloneJobs {
                        if let vol = try? conn.volume(path: src) {
                            let poolDoc = try XMLDocument(xmlString: vol.xml())
                            let fmt = poolDoc.rootElement()?.child("target")?.child("format")?.attr("type") ?? "raw"
                            let info = try vol.info()
                            // Clone into the pool that holds the source volume.
                            let pool = try conn.storagePools().first { p in ((try? p.volumes()) ?? []).contains { $0.path == src } }
                            guard let pool else { throw LibvirtError(message: "Cannot find the storage pool of \(src)") }
                            let x = VolumeXML.make(name: URL(fileURLWithPath: dst).lastPathComponent, format: fmt,
                                                   capacityBytes: info.capacity, allocationBytes: 0)
                            try pool.createVolume(xml: x, cloneFrom: vol)
                        } else if local {
                            let p = Process()
                            p.executableURL = BundledRuntime.bundleContents.appendingPathComponent("MacOS/qemu-img")
                            p.arguments = ["convert", "-O", "qcow2", src, dst]
                            try p.run()
                            p.waitUntilExit()
                            if p.terminationStatus != 0 { throw LibvirtError(message: "qemu-img convert failed for \(src)") }
                        } else {
                            throw LibvirtError(message: "Disk '\(src)' is not in a storage pool and cannot be cloned remotely.")
                        }
                    }
                    try conn.defineDomain(xml: newXML)
                }
                connection.refresh()
                dismiss()
            } catch {
                self.error = "Error creating virtual machine clone '\(name)': \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: Migrate

struct MigrateSheet: View {
    @Environment(AppModel.self) private var app
    let connection: ConnectionModel
    let uuid: String
    @Environment(\.dismiss) private var dismiss

    @StateVar private var destID: UUID?
    @StateVar private var tunnelled = false
    @StateVar private var setAddress = true
    @StateVar private var address = ""
    @StateVar private var setPort = true
    @StateVar private var port = 49152
    @StateVar private var unsafe = false
    @StateVar private var temporary = false
    @StateVar private var error: String?
    @StateVar private var busy = false

    private var domain: DomainSummary? { connection.domain(uuid) }
    private var candidates: [ConnectionModel] {
        app.connections.filter { $0.id != connection.id && $0.status == .connected }
    }
    private var dest: ConnectionModel? { candidates.first { $0.id == destID } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Migrate '\(domain?.name ?? "")'") {
                    LabeledContent("Migrating VM", value: domain?.name ?? "")
                    LabeledContent("Original host", value: "\(connection.hostname) (\(connection.name))")
                    if candidates.isEmpty {
                        Text("No usable connections available.").foregroundStyle(.secondary)
                    } else {
                        Picker("New host", selection: $destID) {
                            ForEach(candidates) { Text("\($0.name) (\($0.uri))").tag(Optional($0.id)) }
                        }
                    }
                }
                Section("Connectivity") {
                    Picker("Mode", selection: $tunnelled) {
                        Text("Direct").tag(false)
                        Text("Tunnelled").tag(true)
                    }
                    if tunnelled {
                        LabeledContent("URI", value: dest?.uri ?? "")
                        if dest?.isLocal == true {
                            Text("A remotely accessible libvirt URI is required for tunneled migration.").foregroundStyle(.orange)
                        }
                    } else {
                        Toggle("Address", isOn: $setAddress)
                        if setAddress { TextField("", text: $address, prompt: Text(dest?.hostname ?? "")).labelsHidden() }
                        else { Text("Let libvirt decide").foregroundStyle(.secondary) }
                        if setAddress {
                            Toggle("Port", isOn: $setPort)
                            if setPort { NumberField(title: "Port", value: $port, range: 1 ... 65535) }
                        }
                    }
                }
                Section("Advanced options") {
                    Toggle("Allow unsafe", isOn: $unsafe)
                    Toggle("Temporary move", isOn: $temporary)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Migrating VM '\(domain?.name ?? "")'. This may take a while.").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Migrate") { migrate() }.keyboardShortcut(.defaultAction).disabled(busy || dest == nil)
            }
            .padding()
        }
        .frame(width: 520, height: 540)
        .onAppear { destID = candidates.first?.id }
        .onChange(of: destID) { address = dest?.hostname ?? "" }
    }

    private func migrate() {
        guard let dest else { return }
        busy = true
        error = nil
        let host = address.isEmpty ? dest.hostname : address
        let migrationURI = (!tunnelled && setAddress) ? "tcp://\(host)\(setPort ? ":\(port)" : "")" : nil
        let tunnelled = self.tunnelled, unsafe = self.unsafe, temporary = self.temporary, uuid = self.uuid
        Task {
            do {
                let destConn = try await dest.withConnection { $0 }
                try await connection.withConnection { conn in
                    try conn.domain(uuid: uuid).migrate(to: destConn, tunnelled: tunnelled, migrationURI: migrationURI,
                                                       unsafe: unsafe, temporary: temporary)
                }
                connection.refresh()
                dest.refresh()
                dismiss()
            } catch {
                self.error = "Unable to migrate guest: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: Delete

struct DeleteStorageRow: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var target: String
    var selected: Bool
    var warning: String?
}

struct DeleteVMSheet: View {
    let connection: ConnectionModel
    let uuid: String
    var onDeleted: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @StateVar private var deleteStorage = true
    @StateVar private var rows: [DeleteStorageRow] = []
    @StateVar private var error: String?
    @StateVar private var busy = false

    private var domain: DomainSummary? { connection.domain(uuid) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Delete '\(domain?.name ?? "")'") {
                    if domain?.state.isActive == true {
                        Label("This VM is currently running and will be forced off before being deleted", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Toggle("Delete associated storage files", isOn: $deleteStorage)
                }
                if deleteStorage {
                    Section("Storage") {
                        ForEach($rows) { $r in
                            HStack {
                                Toggle(isOn: $r.selected) {
                                    VStack(alignment: .leading) {
                                        Text(r.path).lineLimit(1).truncationMode(.middle)
                                        Text(r.target).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if let w = r.warning {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(w)
                                }
                            }
                        }
                        if rows.isEmpty { Text("No storage.").foregroundStyle(.secondary) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Deleting virtual machine…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { delete() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
            .padding()
        }
        .frame(width: 560, height: 460)
        .task { await load() }
    }

    private func load() async {
        let uuid = self.uuid
        guard let result = try? await connection.withConnection({ conn -> (String, [String: [String]]) in
            (try conn.domain(uuid: uuid).xml(inactive: true), StorageModel.diskUsers(conn))
        }), let doc = try? XMLDocument(xmlString: result.0), let root = doc.rootElement() else { return }
        let myName = root.child("name")?.stringValue ?? ""
        var out: [DeleteStorageRow] = []
        for d in root.all("devices/disk") {
            guard let path = d.child("source")?.attr("file") ?? d.child("source")?.attr("dev") else { continue }
            let device = d.attr("device") ?? "disk"
            var warning: String?
            if d.child("readonly") != nil { warning = "Storage is read-only." }
            else if d.child("shareable") != nil { warning = "Storage is marked as shareable." }
            else if device == "cdrom" || device == "floppy" { warning = "Storage is a media device." }
            let others = (result.1[path] ?? []).filter { $0 != myName }
            if !others.isEmpty { warning = "Storage is in use by the following virtual machines: \(others.joined(separator: ", "))" }
            out.append(DeleteStorageRow(path: path, target: d.child("target")?.attr("dev") ?? "", selected: warning == nil, warning: warning))
        }
        for k in ["kernel", "initrd", "dtb"] {
            if let p = root.child("os")?.child(k)?.stringValue, !p.isEmpty {
                out.append(DeleteStorageRow(path: p, target: k, selected: false, warning: "Storage is a media device."))
            }
        }
        rows = out
    }

    private func delete() {
        busy = true
        error = nil
        let paths = deleteStorage ? rows.filter(\.selected).map(\.path) : []
        Task {
            do {
                try await connection.delete(uuid: uuid, storagePaths: paths)
                onDeleted?()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
