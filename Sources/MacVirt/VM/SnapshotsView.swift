// SPDX-License-Identifier: GPL-2.0-or-later
// Snapshots tab of the VM window.

import CLibvirt
import AppKit
import SwiftUI

struct SnapshotRow: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    var state: String
    var created: Date?
    var isCurrent: Bool
    var isExternal: Bool
    var mode: String
    var xml: String

    var stateLabel: String {
        ["running": "Running", "paused": "Paused", "shutdown": "Shutting Down", "shutoff": "Shutoff",
         "crashed": "Crashed", "pmsuspended": "Suspended", "nostate": "Unknown", "blocked": "Unknown"][state] ?? "Shutoff"
    }

    var stateIcon: String {
        switch state {
        case "running", "nostate", "blocked": "play.circle.fill"
        case "paused", "pmsuspended": "pause.circle.fill"
        default: "stop.circle"
        }
    }

    var hasRunState: Bool { state == "running" || state == "paused" }

    init(name: String, xml: String, isCurrent: Bool) {
        self.name = name
        self.xml = xml
        self.isCurrent = isCurrent
        let root = (try? XMLDocument(xmlString: xml))?.rootElement()
        description = root?.child("description")?.stringValue ?? ""
        state = root?.child("state")?.stringValue ?? "shutoff"
        if let t = Double(root?.child("creationTime")?.stringValue ?? "") { created = Date(timeIntervalSince1970: t) }
        let memExternal = root?.child("memory")?.attr("snapshot") == "external"
        let diskExternal = root?.child("disks")?.elements(forName: "disk").contains { $0.attr("snapshot") == "external" } ?? false
        isExternal = memExternal || diskExternal
        mode = memExternal && diskExternal ? "External disk and memory" : memExternal ? "External memory only" : diskExternal ? "External disk only" : "Internal"
    }
}

enum SnapshotScreenshots {
    static func dir(uuid: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacVirt/snapshots/\(uuid)")
    }

    static func url(uuid: String, name: String) -> URL {
        dir(uuid: uuid).appendingPathComponent("\(name).png")
    }

    /// Stores a libvirt screenshot (PNG or PPM) as PNG.
    static func store(_ data: Data, mime: String, uuid: String, name: String) {
        try? FileManager.default.createDirectory(at: dir(uuid: uuid), withIntermediateDirectories: true)
        let dest = url(uuid: uuid, name: name)
        if mime == "image/png" {
            try? data.write(to: dest)
        } else if let image = PPM.decode(data), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: dest)
        }
    }

    static func delete(uuid: String, name: String) {
        try? FileManager.default.removeItem(at: url(uuid: uuid, name: name))
    }
}

/// Minimal binary PPM (P6, maxval 255) decoder for QEMU screenshots.
enum PPM {
    static func decode(_ data: Data) -> CGImage? {
        var tokens: [String] = []
        var i = data.startIndex
        while tokens.count < 4, i < data.endIndex {
            while i < data.endIndex, data[i] == 0x23 { while i < data.endIndex, data[i] != 0x0A { i += 1 } }  // comments
            while i < data.endIndex, [0x20, 0x0A, 0x0D, 0x09].contains(data[i]) { i += 1 }
            var tok = ""
            while i < data.endIndex, ![0x20, 0x0A, 0x0D, 0x09].contains(data[i]) { tok.append(Character(UnicodeScalar(data[i]))); i += 1 }
            if !tok.isEmpty { tokens.append(tok) }
        }
        guard tokens.count == 4, tokens[0] == "P6", let w = Int(tokens[1]), let h = Int(tokens[2]), tokens[3] == "255" else { return nil }
        i += 1
        let pixels = data[i...]
        guard pixels.count >= w * h * 3, let provider = CGDataProvider(data: Data(pixels.prefix(w * h * 3)) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct SnapshotsView: View {
    let connection: ConnectionModel
    let uuid: String

    @StateVar private var snapshots: [SnapshotRow] = []
    @StateVar private var selection = Set<String>()
    @StateVar private var error: String?
    @StateVar private var descriptionDraft = ""
    @StateVar private var creating = false
    @StateVar private var confirmRun = false
    @StateVar private var confirmDelete = false
    @StateVar private var busy: String?

    private var domain: DomainSummary? { connection.domain(uuid) }
    private var selected: SnapshotRow? { selection.count == 1 ? snapshots.first { selection.contains($0.name) } : nil }

    private var internalSnaps: [SnapshotRow] { snapshots.filter { !$0.isExternal } }
    private var externalSnaps: [SnapshotRow] { snapshots.filter(\.isExternal) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(internalSnaps) { row($0) }
                    if !internalSnaps.isEmpty && !externalSnaps.isEmpty { Divider() }
                    ForEach(externalSnaps) { row($0) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1 { Button("Start snapshot") { selection = ids; confirmRun = true } }
                    if !ids.isEmpty { Button("Delete snapshot", role: .destructive) { selection = ids; confirmDelete = true } }
                } primaryAction: { ids in
                    if ids.count == 1 { selection = ids; confirmRun = true }
                }
                HStack(spacing: 2) {
                    Button("Create new snapshot", systemImage: "plus") { creating = true }
                    Button("Run selected snapshot", systemImage: "play.fill") { confirmRun = true }.disabled(selected == nil)
                    Button("Refresh snapshot list", systemImage: "arrow.clockwise") { Task { await load() } }
                    Button("Delete selected snapshot", systemImage: "trash") { confirmDelete = true }.disabled(selection.isEmpty)
                    Spacer()
                    if let busy { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(.secondary) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 380)

            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await load() }
        .onChange(of: selection) { descriptionDraft = selected?.description ?? "" }
        .sheet(isPresented: $creating) {
            CreateSnapshotSheet(connection: connection, uuid: uuid, existing: snapshots) { name in
                Task { await load(select: name) }
            }
        }
        .confirmationDialog(runMessage, isPresented: $confirmRun) {
            Button("Run Snapshot", role: .destructive) { run() }
        }
        .confirmationDialog("Are you sure you want to permanently delete the selected snapshots?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    private func row(_ s: SnapshotRow) -> some View {
        HStack {
            Image(systemName: s.stateIcon).foregroundStyle(s.state == "running" ? .green : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name)
                Text("VM State: \(s.stateLabel)\(s.isExternal ? " (External)" : "")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if s.isCurrent { Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint).help("Current snapshot") }
        }
        .help(s.description)
        .tag(s.name)
    }

    @ViewBuilder private var detail: some View {
        if let error {
            ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if selection.isEmpty {
            ContentUnavailableView("No snapshot selected.", systemImage: "camera")
        } else if let s = selected {
            Form {
                Section("Snapshot '\(s.name)'") {
                    if s.isCurrent {
                        Label("This was the most recently applied snapshot.", systemImage: "info.circle").font(.caption).italic()
                    }
                    ReadOnly("Timestamp", s.created.map { $0.formatted(date: .numeric, time: .standard) } ?? "")
                    LabeledContent("VM State") { Label(s.stateLabel, systemImage: s.stateIcon) }
                    if s.isExternal { ReadOnly("Snapshot Mode", s.mode) }
                    LabeledContent("Description") {
                        TextEditor(text: $descriptionDraft)
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.background.secondary, in: .rect(cornerRadius: 6))
                    }
                    LabeledContent("Screenshot") {
                        if let img = NSImage(contentsOf: SnapshotScreenshots.url(uuid: uuid, name: s.name)) {
                            Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 450, maxHeight: 340)
                        } else {
                            Text("No screenshot available").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Apply") { applyDescription(s) }
                            .disabled(descriptionDraft == s.description)
                            .help("Save updated snapshot metadata")
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Multiple snapshots selected.", systemImage: "square.stack")
        }
    }

    private var runMessage: String {
        let n = selected?.name ?? ""
        return domain?.state.isActive == true
            ? "Are you sure you want to run the snapshot '\(n)'? All the disk changes since the last snapshot was created will be discarded."
            : "Are you sure you want to run the snapshot '\(n)'? All the disk and configuration changes since the last snapshot was created will be discarded."
    }

    private func load(select: String? = nil) async {
        let uuid = self.uuid
        do {
            snapshots = try await connection.withConnection { conn in
                let d = try conn.domain(uuid: uuid)
                return try d.snapshots().map { SnapshotRow(name: $0.name, xml: (try? $0.xml()) ?? "", isCurrent: $0.isCurrent) }
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
            if let select { selection = [select] } else { selection = selection.filter { n in snapshots.contains { $0.name == n } } }
            descriptionDraft = selected?.description ?? ""
        } catch {
            self.error = "Error refreshing snapshot list: \(error.localizedDescription)"
        }
    }

    private func run() {
        guard let s = selected else { return }
        let uuid = self.uuid
        busy = "Running snapshot '\(s.name)'"
        Task {
            do {
                try await connection.withConnection { conn in
                    let d = try conn.domain(uuid: uuid)
                    if d.hasManagedSave && !s.hasRunState { try d.removeManagedSave() }
                    try d.snapshot(named: s.name).revert(start: false, force: false)
                }
            } catch {
                connection.lastError = "Error running snapshot '\(s.name)': \(error.localizedDescription)"
            }
            busy = nil
            connection.refresh()
            await load()
        }
    }

    private func delete() {
        let names = selection
        let uuid = self.uuid
        busy = "Deleting snapshot"
        Task {
            for name in names {
                do {
                    try await connection.withConnection { try $0.domain(uuid: uuid).snapshot(named: name).delete() }
                    SnapshotScreenshots.delete(uuid: uuid, name: name)
                } catch {
                    connection.lastError = "Error deleting snapshot '\(name)': \(error.localizedDescription)"
                }
            }
            busy = nil
            await load()
        }
    }

    private func applyDescription(_ s: SnapshotRow) {
        guard let doc = try? XMLDocument(xmlString: s.xml), let root = doc.rootElement() else { return }
        if descriptionDraft.isEmpty { root.removeChildren(named: "description") }
        else { root.ensure("description").stringValue = descriptionDraft }
        let xml = doc.xmlString
        let uuid = self.uuid
        Task {
            do {
                try await connection.withConnection {
                    try $0.domain(uuid: uuid).createSnapshot(xml: xml, flags: UInt32(VIR_DOMAIN_SNAPSHOT_CREATE_REDEFINE.rawValue))
                }
            } catch {
                connection.lastError = error.localizedDescription
            }
            await load(select: s.name)
        }
    }
}

struct CreateSnapshotSheet: View {
    let connection: ConnectionModel
    let uuid: String
    let existing: [SnapshotRow]
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateVar private var name = ""
    @StateVar private var external = false
    @StateVar private var autoMemoryPath = true
    @StateVar private var memoryPath = ""
    @StateVar private var description = ""
    @StateVar private var error: String?
    @StateVar private var busy = false
    @StateVar private var diskDirs: [String] = []
    @StateVar private var confirmMix = false

    private var domain: DomainSummary? { connection.domain(uuid) }
    private var active: Bool { domain?.state.isActive ?? false }
    private var current: SnapshotRow? { existing.first(where: \.isCurrent) }

    private var autoPath: String {
        "\(diskDirs.first ?? "/var/lib/libvirt/qemu/snapshot")/\(domain?.name ?? "vm")-mem.\(name)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Create snapshot") {
                    TextField("Name", text: $name)
                    LabeledContent("Status") {
                        Label(domain?.state.label ?? "", systemImage: active ? "play.circle.fill" : "stop.circle")
                    }
                    Picker("Snapshot Mode", selection: $external) {
                        Text("Internal").tag(false)
                        Text("External").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    if external && active {
                        Toggle("Memory state: automatic path", isOn: $autoMemoryPath)
                        TextField("Memory state file", text: autoMemoryPath ? .constant(autoPath) : $memoryPath)
                            .disabled(autoMemoryPath)
                    }
                    LabeledContent("Description") {
                        TextEditor(text: $description)
                            .frame(minHeight: 60)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.background.secondary, in: .rect(cornerRadius: 6))
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Creating virtual machine snapshot").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Finish") {
                    if let current, current.isExternal != external { confirmMix = true } else { create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || name.contains("/") || busy)
            }
            .padding()
        }
        .frame(width: 500)
        .confirmationDialog("Mixing external and internal snapshots for the same VM is not recommended. Are you sure you want to continue?",
                            isPresented: $confirmMix) {
            Button("Continue") { create() }
        }
        .task {
            var n = 1
            let names = Set(existing.map(\.name))
            while names.contains("snapshot\(n)") { n += 1 }
            name = "snapshot\(n)"
            external = current.map(\.isExternal) ?? false
            let uuid = self.uuid
            diskDirs = (try? await connection.withConnection { conn in
                let xml = try conn.domain(uuid: uuid).xml(inactive: true)
                let doc = try XMLDocument(xmlString: xml)
                return Array(Set(doc.rootElement()?.all(".//disk[@device='disk']/source").compactMap { $0.attr("file") }
                    .map { ($0 as NSString).deletingLastPathComponent } ?? [])).sorted()
            }) ?? []
        }
    }

    private func create() {
        busy = true
        error = nil
        var xml = "<domainsnapshot><name>\(name.xmlEscaped)</name>"
        if !description.isEmpty { xml += "<description>\(description.xmlEscaped)</description>" }
        if external && active {
            xml += "<memory snapshot='external' file='\((autoMemoryPath ? autoPath : memoryPath).xmlEscaped)'/>"
        }
        if external && !active {
            // Disk-only external snapshot; every disk external.
        }
        xml += "</domainsnapshot>"
        let snapshotXML = xml
        let flags = (external && !active) ? UInt32(VIR_DOMAIN_SNAPSHOT_CREATE_DISK_ONLY.rawValue) : 0
        let uuid = self.uuid, name = self.name, takeShot = active
        Task {
            do {
                // Screenshot first (twice: the first frame can be stale with qxl).
                if takeShot {
                    let shot = try? await connection.withConnection { conn -> (Data, String) in
                        let d = try conn.domain(uuid: uuid)
                        _ = try? d.screenshot(connection: conn)
                        return try d.screenshot(connection: conn)
                    }
                    if let shot { SnapshotScreenshots.store(shot.0, mime: shot.1, uuid: uuid, name: name) }
                }
                _ = try await connection.withConnection { try $0.domain(uuid: uuid).createSnapshot(xml: snapshotXML, flags: flags) }
                onCreated(name)
                dismiss()
            } catch {
                var msg = "Error creating snapshot: \(error.localizedDescription)"
                if msg.contains("nvram") {
                    msg += "\n\nThis UEFI VM keeps its NVRAM in raw format, which only allows external snapshots. Choose External mode. (VMs created with MacVirt 0.2 or later support internal snapshots.)"
                }
                self.error = msg
            }
            busy = false
        }
    }
}
