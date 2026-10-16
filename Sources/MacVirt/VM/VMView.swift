// SPDX-License-Identifier: GPL-2.0-or-later
// The VM window: Console / Details / Snapshots, as in virt-manager.

import AppKit
import SwiftUI

enum VMTab: String, Codable, Hashable, CaseIterable {
    case console, details, snapshots

    var title: String {
        switch self {
        case .console: "Console"
        case .details: "Details"
        case .snapshots: "Snapshots"
        }
    }

    var symbol: String {
        switch self {
        case .console: "display"
        case .details: "info.circle"
        case .snapshots: "camera"
        }
    }
}

/// Identifies a VM window. Codable so SwiftUI can restore it.
struct VMTarget: Codable, Hashable {
    var connectionID: UUID
    var domainUUID: String
    var tab: VMTab = .console
}

struct TextConsole: Hashable {
    var alias: String
    var label: String
}

struct VMView: View {
    let connection: ConnectionModel
    let uuid: String
    var initialTab: VMTab = .details
    var showsTabPicker = true

    @StateVar private var tab: VMTab = .details
    @StateVar private var editor: DomainEditor?
    @StateVar private var console = ConsoleSession()
    @StateVar private var textConsoles: [TextConsole] = []
    /// nil = graphical console
    @StateVar private var textConsole: String?
    @StateVar private var scale = Preferences.shared.consoleScaling != 0
    @StateVar private var pendingAction: DomainAction?
    @StateVar private var showClone = false
    @StateVar private var showMigrate = false
    @StateVar private var showDelete = false

    private var domain: DomainSummary? { connection.domain(uuid) }

    var body: some View {
        Group {
            switch tab {
            case .console:
                if let alias = textConsole {
                    SerialConsoleView(connection: connection, uuid: uuid, alias: alias).id(alias)
                } else {
                    GraphicalConsoleView(connection: connection, uuid: uuid, session: console, scale: scale)
                }
            case .details:
                if let editor { HardwareEditorView(editor: editor) } else { ProgressView() }
            case .snapshots:
                SnapshotsView(connection: connection, uuid: uuid)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .navigationTitle(domain?.name ?? "Virtual Machine")
        .navigationSubtitle("\(domain?.state.label ?? "") · \(connection.name)")
        .toolbar { toolbar }
        .onAppear {
            tab = initialTab
            if editor == nil {
                let e = DomainEditor(connection: connection, uuid: uuid)
                editor = e
                Task { await e.load() }
            }
        }
        .task(id: connection.generation) {
            await loadTextConsoles()
            if let editor, !editor.isDirty { await editor.load() }
        }
        .confirmationDialog(confirmText, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            if let a = pendingAction {
                Button(a.title, role: a.isDestructive ? .destructive : nil) { connection.perform(a, on: uuid) }
            }
        }
        .sheet(isPresented: $showClone) { CloneSheet(connection: connection, uuid: uuid) }
        .sheet(isPresented: $showMigrate) { MigrateSheet(connection: connection, uuid: uuid) }
        .sheet(isPresented: $showDelete) { DeleteVMSheet(connection: connection, uuid: uuid) }
    }

    private var confirmText: String {
        guard let a = pendingAction, let name = domain?.name else { return "" }
        switch a {
        case .forceOff: return "Are you sure you want to force poweroff '\(name)'? This will immediately power off the VM without shutting down the OS and may cause data loss."
        case .reset: return "Are you sure you want to force reset '\(name)'? This will immediately reset the VM without shutting down the OS and may cause data loss."
        case .shutdown: return "Are you sure you want to shut down '\(name)'?"
        case .reboot: return "Are you sure you want to reboot '\(name)'?"
        case .pause: return "Are you sure you want to pause '\(name)'?"
        case .save: return "Are you sure you want to save '\(name)'?"
        default: return ""
        }
    }

    private func request(_ a: DomainAction) {
        let p = Preferences.shared
        let needsConfirm = switch a {
        case .forceOff, .reset: p.confirmForceOff
        case .shutdown, .reboot, .save: p.confirmPowerOff
        case .pause: p.confirmPause
        default: false
        }
        if needsConfirm { pendingAction = a } else { connection.perform(a, on: uuid) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if showsTabPicker {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $tab) {
                    ForEach(VMTab.allCases, id: \.self) { t in
                        Label(t.title, systemImage: t.symbol).accessibilityLabel(t.title).help(t.title).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .help("Console / Details / Snapshots")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let state = domain?.state ?? .noState
            Button("Run", systemImage: "play.fill") { request(.start) }.disabled(!DomainAction.start.isAvailable(for: state))
            if state == .paused {
                Button("Resume", systemImage: "playpause.fill") { request(.resume) }
            } else {
                Button("Pause", systemImage: "pause.fill") { request(.pause) }.disabled(!DomainAction.pause.isAvailable(for: state))
            }
            Menu {
                ForEach(DomainAction.shutdownMenu, id: \.self) { a in
                    Button(a.title, systemImage: a.symbol) { request(a) }.disabled(!a.isAvailable(for: state))
                }
            } label: {
                Label("Shut Down", systemImage: "power")
            } primaryAction: {
                request(.shutdown)
            }
            .disabled(!state.isActive)

            if tab == .console {
                Menu {
                    Section("Consoles") {
                        Picker("Console", selection: $textConsole) {
                            Text("Graphical Console").tag(String?.none)
                            ForEach(textConsoles, id: \.alias) { Text($0.label).tag(Optional($0.alias)) }
                        }
                        .pickerStyle(.inline)
                    }
                    if textConsole == nil {
                        Section("Send Key") {
                            ForEach(KeySyms.sendKeyMenu, id: \.0) { title, keys in
                                Button(title) { console.view.sendCombo(keys) }
                            }
                        }
                        Section {
                            Toggle("Scale Display to Window", isOn: $scale)
                            Button("Take Screenshot…") { console.saveScreenshot(name: domain?.name ?? "vm") }
                            Button("Reconnect") { console.connect(connection: connection, domainUUID: uuid) }
                        }
                    }
                } label: {
                    Label("Console", systemImage: "keyboard")
                }
                Button("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
            Menu {
                Button("Clone…") { showClone = true }
                Button("Migrate…") { showMigrate = true }.disabled(!state.isActive && false)
                Divider()
                Button("Delete…", role: .destructive) { showDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func loadTextConsoles() async {
        guard let details = try? await connection.domainXML(uuid: uuid, inactive: false),
              let doc = try? XMLDocument(xmlString: details) else { return }
        var out: [TextConsole] = []
        let devices = doc.rootElement()?.child("devices")
        let serials = devices?.elements(forName: "serial") ?? []
        for s in serials where (s.attr("type") ?? "pty") == "pty" {
            let port = (Int(s.child("target")?.attr("port") ?? "") ?? 0) + 1
            if let alias = s.child("alias")?.attr("name") { out.append(TextConsole(alias: alias, label: "Serial \(port)")) }
        }
        for (i, c) in (devices?.elements(forName: "console") ?? []).enumerated() where (c.attr("type") ?? "pty") == "pty" {
            // console0 of target type serial duplicates serial0.
            if i == 0, !serials.isEmpty, (c.child("target")?.attr("type") ?? "serial") == "serial" { continue }
            let port = (Int(c.child("target")?.attr("port") ?? "") ?? 0) + 1
            let type = c.child("target")?.attr("type") ?? ""
            if let alias = c.child("alias")?.attr("name") { out.append(TextConsole(alias: alias, label: "Text Console \(port) (\(type))")) }
        }
        textConsoles = out
        if let t = textConsole, !out.contains(where: { $0.alias == t }) { textConsole = nil }
    }
}

/// Hardware list + page + Add/Remove/Apply/Revert (the Details tab).
struct HardwareEditorView: View {
    let editor: DomainEditor
    @StateVar private var selection: String? = "overview"
    @StateVar private var addHardware = false
    @StateVar private var confirmRemove: HardwareItem?
    @StateVar private var showDomainXML = false

    private var items: [HardwareItem] { editor.hardwareItems }
    private var selected: HardwareItem? { items.first { $0.id == selection } ?? items.first }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(items, selection: $selection) { item in
                        Label(item.label, systemImage: item.icon).tag(item.id)
                            .contextMenu {
                                if item.isDevice { Button("Remove Hardware", role: .destructive) { confirmRemove = item } }
                            }
                    }
                    HStack {
                        Button("Add Hardware", systemImage: "plus") { addHardware = true }
                        Spacer()
                        Button("Remove", systemImage: "minus") { if let s = selected, s.isDevice { confirmRemove = s } }
                            .disabled(!(selected?.isDevice ?? false))
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

                Group {
                    if let error = editor.loadError {
                        ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else if editor.doc == nil {
                        ProgressView()
                    } else if let item = selected {
                        HardwarePage(editor: editor, item: item).id(item.id)
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if let msg = editor.applyMessage {
                    Label(msg, systemImage: "info.circle").foregroundStyle(.secondary).lineLimit(2)
                } else if editor.isDirty {
                    Label("Unapplied changes", systemImage: "pencil.circle").foregroundStyle(.orange)
                }
                Spacer()
                if editor.busy { ProgressView().controlSize(.small) }
                Button("Edit Domain XML…") { showDomainXML = true }
                    .disabled(!Preferences.shared.xmlEditingEnabled)
                Button("Revert") { Task { await editor.revert() } }.disabled(!editor.isDirty)
                Button("Apply") { Task { await editor.apply() } }
                    .keyboardShortcut("s")
                    .buttonStyle(.glassProminent)
                    .disabled(!editor.isDirty || editor.busy)
            }
            .padding(10)
        }
        .sheet(isPresented: $addHardware) { AddHardwareSheet(editor: editor) }
        .sheet(isPresented: $showDomainXML) {
            XMLEditorSheet(title: "Domain XML — \(editor.name)", xml: editor.xmlString) { xml in
                try await editor.connection.define(xml: xml)
                await editor.load()
            }
        }
        .confirmationDialog("Are you sure you want to remove this device?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove \(confirmRemove?.label ?? "")", role: .destructive) {
                if let item = confirmRemove { Task { await remove(item) } }
            }
        } message: {
            Text(editor.isDirty ? "Unapplied changes will be discarded." : "")
        }
    }

    private func remove(_ item: HardwareItem) async {
        guard let el = item.element else { return }
        let xml = el.xmlString
        let uuid = editor.uuid
        let running = editor.isRunning
        do {
            let note: String? = try await editor.connection.withConnection { conn in
                let d = try conn.domain(uuid: uuid)
                if running {
                    do {
                        try d.detachDevice(xml, scope: .both)
                        return nil
                    } catch {
                        try d.detachDevice(xml, scope: .config)
                        return "The device could not be removed from the running VM; it will be removed after the next guest shutdown."
                    }
                }
                try d.detachDevice(xml, scope: .config)
                return nil
            }
            await editor.load()
            editor.applyMessage = note
            selection = "overview"
        } catch {
            editor.connection.lastError = "Error removing device: \(error.localizedDescription)"
        }
    }
}
