// SPDX-License-Identifier: GPL-2.0-or-later
// Storage pools and volumes: the Storage tab of Connection Details and the
// "Choose Storage Volume" sheet.

import AppKit
import SwiftUI

struct PoolRow: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var type: String
    var info: PoolInfo
    var active: Bool
    var autostart: Bool
    var path: String
    var xml: String

    var percentUsed: Int { info.capacity > 0 ? Int(Double(info.allocation) / Double(info.capacity) * 100) : 0 }
}

struct VolumeRow: Identifiable, Hashable, Sendable {
    var id: String { path.isEmpty ? name : path }
    var name: String
    var path: String
    var capacity: UInt64
    var allocation: UInt64
    var format: String
    var usedBy: String
}

enum PoolTypes {
    static let all: [(String, String)] = [
        ("dir", "Filesystem Directory"), ("disk", "Physical Disk Device"), ("fs", "Pre-Formatted Block Device"),
        ("gluster", "Gluster Filesystem"), ("iscsi", "iSCSI Target"), ("logical", "LVM Volume Group"),
        ("mpath", "Multipath Device Enumerator"), ("netfs", "Network Exported Directory"),
        ("rbd", "RADOS Block Device/Ceph"), ("scsi", "SCSI Host Adapter"), ("zfs", "ZFS Pool"),
    ]
    static func pretty(_ t: String) -> String { all.first { $0.0 == t }?.1 ?? "\(t) pool" }
    static let supportsVolumeCreation: Set<String> = ["dir", "fs", "netfs", "disk", "logical", "rbd", "zfs"]
}

@MainActor @Observable
final class StorageModel {
    let connection: ConnectionModel
    var pools: [PoolRow] = []
    var selectedPool: String?
    var volumes: [VolumeRow] = []
    var selectedVolume: VolumeRow.ID?
    var error: String?
    var busy = false

    init(connection: ConnectionModel) { self.connection = connection }

    var pool: PoolRow? { pools.first { $0.name == selectedPool } }

    func load(select: String? = nil) async {
        do {
            pools = try await connection.withConnection { conn in
                try conn.storagePools().map { p in
                    let xml = (try? p.xml()) ?? ""
                    let doc = try? XMLDocument(xmlString: xml)
                    return PoolRow(
                        name: p.name, type: doc?.rootElement()?.attr("type") ?? "",
                        info: (try? p.info()) ?? PoolInfo(state: .inactive, capacity: 0, allocation: 0, available: 0),
                        active: p.isActive, autostart: p.autostart,
                        path: doc?.rootElement()?.child("target")?.child("path")?.stringValue ?? "", xml: xml)
                }
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if let select { selectedPool = select }
            if selectedPool == nil || pool == nil {
                selectedPool = pools.first { $0.name == "default" }?.name ?? pools.first?.name
            }
            error = nil
            await loadVolumes()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadVolumes(select: String? = nil) async {
        guard let pool, pool.active else { volumes = []; return }
        let name = pool.name
        do {
            volumes = try await connection.withConnection { conn in
                let usedBy = Self.diskUsers(conn)
                return try conn.storagePool(named: name).volumes().compactMap { v -> VolumeRow? in
                    guard let info = try? v.info() else { return nil }
                    let path = v.path
                    let fmt = (try? XMLDocument(xmlString: v.xml()))?.rootElement()?.child("target")?.child("format")?.attr("type") ?? ""
                    return VolumeRow(name: v.name, path: path, capacity: info.capacity, allocation: info.allocation,
                                     format: fmt, usedBy: (usedBy[path] ?? []).joined(separator: ", "))
                }
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if let select { selectedVolume = volumes.first { $0.name == select }?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Maps disk source paths (incl. backing chains) to the VMs using them.
    nonisolated static func diskUsers(_ conn: Connection) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for d in (try? conn.allDomains()) ?? [] {
            guard let xml = try? d.xml(inactive: true), let doc = try? XMLDocument(xmlString: xml) else { continue }
            let name = d.name
            for src in doc.rootElement()?.all(".//disk//source") ?? [] {
                if let p = src.attr("file") ?? src.attr("dev") { map[p, default: []].append(name) }
            }
        }
        return map.mapValues { Array(Set($0)).sorted() }
    }

    func poolAction(_ action: @escaping @Sendable (StoragePool) throws -> Void) {
        guard let name = selectedPool else { return }
        Task {
            do {
                try await connection.withConnection { try action(try $0.storagePool(named: name)) }
            } catch { self.error = error.localizedDescription }
            await load()
        }
    }

    func deleteVolume(_ row: VolumeRow) {
        guard let name = selectedPool else { return }
        Task {
            do {
                try await connection.withConnection { conn in
                    let pool = try conn.storagePool(named: name)
                    try pool.volume(named: row.name).delete()
                    try? pool.refresh()
                }
            } catch { self.error = error.localizedDescription }
            await load()
        }
    }
}

/// Pool list + pool details + volume table. Used standalone (Connection
/// Details) and as a chooser (`onChoose` set).
struct StorageManagerView: View {
    let connection: ConnectionModel
    var onChoose: ((String) -> Void)?
    @StateVar private var model: StorageModel?
    @StateVar private var addPool = false
    @StateVar private var addVolume = false
    @StateVar private var confirmDeletePool = false
    @StateVar private var deletingVolume: VolumeRow?
    @StateVar private var showXML = false

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .task {
            let m = StorageModel(connection: connection)
            model = m
            await m.load()
        }
    }

    @ViewBuilder private func content(_ m: StorageModel) -> some View {
        @Bindable var m = m
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $m.selectedPool) {
                    ForEach(m.pools) { p in
                        HStack(spacing: 8) {
                            Text("\(p.percentUsed)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name)
                                Text(PoolTypes.pretty(p.type)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .opacity(p.active ? 1 : 0.5)
                        .tag(p.name)
                    }
                }
                HStack(spacing: 2) {
                    Button("Add Pool", systemImage: "plus") { addPool = true }
                    Button("Start Pool", systemImage: "play.fill") { m.poolAction { try $0.start() } }
                        .disabled(m.pool?.active ?? true)
                    Button("Stop Pool", systemImage: "stop.fill") { m.poolAction { try $0.stop() } }
                        .disabled(!(m.pool?.active ?? false))
                    Button("Delete Pool", systemImage: "trash") { confirmDeletePool = true }
                        .disabled(m.pool?.active ?? true)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

            VStack(alignment: .leading, spacing: 10) {
                if let error = m.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                }
                if let p = m.pool {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { Text("Name:").foregroundStyle(.secondary); Text(p.name).bold() }
                        GridRow {
                            Text("Size:").foregroundStyle(.secondary)
                            Text("\(Pretty.gib(p.info.available)) Free / ") + Text("\(Pretty.gib(p.info.allocation)) In Use").italic()
                        }
                        GridRow { Text("Location:").foregroundStyle(.secondary); Text(p.path).textSelection(.enabled) }
                        if onChoose == nil {
                            GridRow {
                                Text("State:").foregroundStyle(.secondary)
                                Label(p.active ? "Active" : "Inactive", systemImage: p.active ? "play.circle.fill" : "stop.circle")
                            }
                            GridRow {
                                Text("Autostart:").foregroundStyle(.secondary)
                                Toggle("On Boot", isOn: Binding(get: { p.autostart }, set: { on in m.poolAction { try $0.setAutostart(on) } }))
                            }
                        }
                    }
                    HStack {
                        Text("Volumes").font(.headline)
                        Button("Create new volume", systemImage: "plus") { addVolume = true }
                            .disabled(!p.active || !PoolTypes.supportsVolumeCreation.contains(p.type))
                        Button("Refresh volume list", systemImage: "arrow.clockwise") {
                            m.poolAction { try $0.refresh() }
                        }.disabled(!p.active)
                        Button("Delete volume", systemImage: "trash") {
                            deletingVolume = m.volumes.first { $0.id == m.selectedVolume }
                        }.disabled(m.selectedVolume == nil)
                        Spacer()
                        if onChoose == nil {
                            Button("XML…") { showXML = true }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    Table(m.volumes, selection: $m.selectedVolume) {
                        TableColumn("Volumes", value: \.name)
                        TableColumn("Size") { Text(Pretty.gib($0.capacity)) }.width(90)
                        TableColumn("Format", value: \.format).width(60)
                        TableColumn("Used By", value: \.usedBy)
                    }
                    .contextMenu(forSelectionType: VolumeRow.ID.self) { ids in
                        if let id = ids.first, let v = m.volumes.first(where: { $0.id == id }) {
                            Button("Copy Volume Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(v.path, forType: .string)
                            }
                        }
                    } primaryAction: { ids in
                        if let onChoose, let id = ids.first, let v = m.volumes.first(where: { $0.id == id }) { onChoose(v.path) }
                    }
                    .disabled(!p.active)
                } else {
                    ContentUnavailableView("No storage pool selected", systemImage: "externaldrive")
                }
            }
            .padding()
            .frame(minWidth: 420)
        }
        .onChange(of: m.selectedPool) { Task { await m.loadVolumes() } }
        .sheet(isPresented: $addPool) {
            CreatePoolSheet(connection: connection) { name in Task { await m.load(select: name) } }
        }
        .sheet(isPresented: $addVolume) {
            if let p = m.pool {
                CreateVolumeSheet(connection: connection, pool: p) { name in Task { await m.loadVolumes(select: name) } }
            }
        }
        .sheet(isPresented: $showXML) {
            if let p = m.pool {
                XMLEditorSheet(title: "Pool \(p.name)", xml: p.xml) { xml in
                    try await connection.withConnection { try $0.defineStoragePool(xml: xml) }
                    await m.load()
                }
            }
        }
        .confirmationDialog("Are you sure you want to permanently delete the pool \(m.pool?.name ?? "")?", isPresented: $confirmDeletePool) {
            Button("Delete", role: .destructive) { m.poolAction { try $0.undefine() } }
        }
        .confirmationDialog("Are you sure you want to permanently delete the volume \(deletingVolume?.name ?? "")?",
                            isPresented: Binding(get: { deletingVolume != nil }, set: { if !$0 { deletingVolume = nil } })) {
            Button("Delete", role: .destructive) {
                if let v = deletingVolume { m.deleteVolume(v) }
                deletingVolume = nil
            }
        }
    }
}

/// "Choose Storage Volume" sheet.
struct StorageBrowser: View {
    enum Purpose { case disk, media, directory }

    let connection: ConnectionModel
    let purpose: Purpose
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            StorageManagerView(connection: connection) { path in
                onChoose(path)
                dismiss()
            }
            Divider()
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Button("Browse Local…") { browseLocal() }
                    .disabled(!connection.isLocal)
                    .help(connection.isLocal ? "Browse local filesystem" : "Cannot use local storage on remote connection.")
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 860, minHeight: 480)
    }

    private var title: String {
        switch purpose {
        case .disk: "Locate or create storage volume — double-click a volume to choose it"
        case .media: "Locate ISO media volume — double-click a volume to choose it"
        case .directory: "Locate directory volume"
        }
    }

    private func browseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = purpose == .directory
        panel.canChooseFiles = purpose != .directory
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onChoose(url.path)
            dismiss()
        }
    }
}

struct CreatePoolSheet: View {
    let connection: ConnectionModel
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateVar private var name = "pool"
    @StateVar private var type = "dir"
    @StateVar private var target = ""
    @StateVar private var sourcePath = ""
    @StateVar private var host = ""
    @StateVar private var format = "auto"
    @StateVar private var sourceName = ""
    @StateVar private var useIQN = false
    @StateVar private var iqn = ""
    @StateVar private var error: String?
    @StateVar private var busy = false

    private func show(_ field: String) -> Bool {
        let m: [String: Set<String>] = [
            "target": ["dir", "fs", "netfs", "iscsi", "scsi", "mpath"],
            "source": ["fs", "netfs", "disk", "iscsi", "scsi", "gluster"],
            "host": ["netfs", "iscsi", "gluster", "rbd"],
            "format": ["fs", "netfs", "disk"],
            "iqn": ["iscsi"],
            "sourceName": ["logical", "gluster", "rbd", "zfs"],
        ]
        return m[field]?.contains(type) ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Create storage pool") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        ForEach(PoolTypes.all, id: \.0) { Text("\($0.0): \($0.1)").tag($0.0) }
                    }
                }
                Section {
                    if show("target") { TextField("Target Path", text: $target, prompt: Text(defaultTarget)) }
                    if show("source") {
                        TextField(type == "iscsi" ? "Source IQN" : type == "scsi" ? "Source Adapter" : "Source Path", text: $sourcePath,
                                  prompt: Text(type == "netfs" || type == "gluster" ? "/export/path" : type == "scsi" ? "host0" : "/dev/sdb"))
                    }
                    if show("host") { TextField("Host Name", text: $host) }
                    if show("format") { TextField("Format", text: $format) }
                    if show("iqn") {
                        Toggle("Initiator IQN", isOn: $useIQN)
                        if useIQN { TextField("IQN", text: $iqn) }
                    }
                    if show("sourceName") {
                        TextField(type == "logical" ? "Volgroup Name" : "Source Name", text: $sourceName,
                                  prompt: Text(type == "rbd" ? "rbd" : type == "gluster" ? "gv0" : ""))
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Creating storage pool…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Finish") { create() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || name.contains("/") || busy)
            }
            .padding()
        }
        .frame(width: 520)
        .onChange(of: type) { target = "" }
    }

    private var defaultTarget: String {
        switch type {
        case "iscsi", "scsi": "/dev/disk/by-path"
        case "mpath": "/dev/mapper"
        default: connection.isLocal
            ? BundledRuntime.baseDir.appendingPathComponent("data/libvirt/images/\(name)").path
            : "/var/lib/libvirt/images/\(name)"
        }
    }

    private var xml: String {
        var source = ""
        if show("format"), !(type == "disk" && format == "auto"), !format.isEmpty { source += "<format type='\(format.xmlEscaped)'/>" }
        if show("host"), !host.isEmpty { source += "<host name='\(host.xmlEscaped)'/>" }
        if show("source"), !sourcePath.isEmpty {
            switch type {
            case "netfs", "gluster": source += "<dir path='\(sourcePath.xmlEscaped)'/>"
            case "scsi": source += "<adapter name='\(sourcePath.xmlEscaped)'/>"
            default: source += "<device path='\(sourcePath.xmlEscaped)'/>"
            }
        }
        if show("sourceName") {
            let n = sourceName.isEmpty ? (type == "rbd" ? "rbd" : type == "gluster" ? "gv0" : name) : sourceName
            source += "<name>\(n.xmlEscaped)</name>"
        }
        if show("iqn"), useIQN, !iqn.isEmpty { source += "<initiator><iqn name='\(iqn.xmlEscaped)'/></initiator>" }
        var targetXML = ""
        if show("target") || type == "disk" {
            let t = target.isEmpty ? (type == "disk" ? "/dev" : defaultTarget) : target
            targetXML = "<target><path>\(t.xmlEscaped)</path></target>"
        }
        return "<pool type='\(type)'><name>\(name.xmlEscaped)</name>\(source.isEmpty ? "" : "<source>\(source)</source>")\(targetXML)</pool>"
    }

    private func create() {
        busy = true
        error = nil
        let xml = self.xml, build = ["dir", "fs", "netfs"].contains(type), name = self.name
        Task {
            do {
                try await connection.withConnection { conn in
                    let pool = try conn.defineStoragePool(xml: xml)
                    do {
                        if build { try pool.build() }
                        try pool.start()
                        try pool.setAutostart(true)
                    } catch {
                        try? pool.undefine()
                        throw error
                    }
                }
                onCreated(name)
                dismiss()
            } catch {
                self.error = "Error creating pool: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

struct CreateVolumeSheet: View {
    let connection: ConnectionModel
    let pool: PoolRow
    var nameHint = "vol"
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateVar private var name = ""
    @StateVar private var format = "qcow2"
    @StateVar private var capacityGiB = 20.0
    @StateVar private var allocateNow = false
    @StateVar private var backing = ""
    @StateVar private var error: String?
    @StateVar private var busy = false

    private var isFilePool: Bool { ["dir", "fs", "netfs"].contains(pool.type) }
    private var suffix: String {
        guard isFilePool, !name.contains(".") else { return "" }
        return format == "raw" ? ".img" : ".\(format)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Create storage volume") {
                    LabeledContent("Name") {
                        HStack { TextField("", text: $name).labelsHidden(); Text(suffix).foregroundStyle(.secondary) }
                    }
                    if isFilePool {
                        Picker("Format", selection: $format) {
                            Text("qcow2").tag("qcow2")
                            Text("raw").tag("raw")
                        }
                    }
                }
                Section("Storage Volume Quota") {
                    Text("\(pool.name)'s available space: \(Pretty.gib(pool.info.available))").foregroundStyle(.secondary)
                    LabeledContent("Capacity") {
                        HStack {
                            TextField("", value: $capacityGiB, format: .number.precision(.fractionLength(1))).frame(width: 90)
                            Stepper("", value: $capacityGiB, in: 0.1 ... 1_000_000).labelsHidden()
                            Text("GiB")
                        }
                    }
                    if isFilePool || pool.type == "zfs" {
                        Toggle("Allocate entire volume now", isOn: $allocateNow)
                    }
                }
                if format == "qcow2" || pool.type == "logical" {
                    Section("Backing store") {
                        TextField("Path", text: $backing, prompt: Text("None"))
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Creating storage volume…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Finish") { create() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || name.contains("/") || busy)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear {
            name = nameHint
            capacityGiB = min(20, max(0.1, Double(pool.info.available) / 1_073_741_824))
        }
        .onChange(of: format) { allocateNow = format != "qcow2" }
    }

    private func create() {
        let capacity = UInt64(capacityGiB * 1_073_741_824)
        let alloc = (allocateNow || pool.type == "logical") ? capacity : 0
        guard alloc <= pool.info.available || pool.info.available == 0 else {
            error = "There is not enough free space on the storage pool to create the volume."
            return
        }
        busy = true
        let fullName = name + suffix
        let xml = VolumeXML.make(name: fullName, format: isFilePool ? format : "raw", capacityBytes: capacity, allocationBytes: alloc,
                                 backingPath: backing.isEmpty ? nil : backing, backingFormat: nil)
        let poolName = pool.name
        Task {
            do {
                try await connection.withConnection { conn in
                    let p = try conn.storagePool(named: poolName)
                    try p.createVolume(xml: xml)
                    try? p.refresh()
                }
                onCreated(fullName)
                dismiss()
            } catch {
                self.error = "Error creating vol: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

/// Generic XML editor sheet for pools, networks, snapshots and domains.
struct XMLEditorSheet: View {
    let title: String
    @StateVar var xml: String
    let onApply: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateVar private var error: String?

    init(title: String, xml: String, onApply: @escaping (String) async throws -> Void) {
        self.title = title
        _xml = StateVar(initialValue: xml)
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            TextEditor(text: $xml).font(.system(.body, design: .monospaced))
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    Task {
                        do { try await onApply(xml); dismiss() } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
    }
}
