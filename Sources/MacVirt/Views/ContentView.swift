// SPDX-License-Identifier: GPL-2.0-or-later
// The manager window: connections and their VMs, like virt-manager's main window.

import Charts
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @StateVar private var router = SheetRouter.shared
    @StateVar private var collapsed: Set<UUID> = []
    @StateVar private var sheetTarget: VMSheet?
    @StateVar private var confirm: (ConnectionModel, DomainSummary, DomainAction)?
    @StateVar private var removingConnection: ConnectionModel?

    enum VMSheet: Identifiable {
        case clone(ConnectionModel, String), migrate(ConnectionModel, String), delete(ConnectionModel, String)
        var id: String {
            switch self {
            case .clone(_, let u): "clone-\(u)"
            case .migrate(_, let u): "migrate-\(u)"
            case .delete(_, let u): "delete-\(u)"
            }
        }
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selection) {
                ForEach(app.connections) { conn in
                    DisclosureGroup(isExpanded: expandedBinding(conn.id)) {
                        ForEach(conn.domains) { d in
                            DomainRow(domain: d, history: conn.history[d.uuid] ?? [])
                                .tag(SidebarItem.domain(conn.id, d.uuid))
                        }
                    } label: {
                        ConnectionHeader(connection: conn)
                            .tag(SidebarItem.connection(conn.id))
                    }
                }
            }
            .contextMenu(forSelectionType: SidebarItem.self) { items in
                if let item = items.first { menu(for: item) }
            } primaryAction: { items in
                guard let item = items.first, let conn = app.connection(item.connectionID) else { return }
                switch item {
                case .domain(_, let uuid): openWindow(id: "vm", value: VMTarget(connectionID: conn.id, domainUUID: uuid, tab: .console))
                case .connection: if conn.status != .connected { conn.connect() }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .toolbar {
                ToolbarItem {
                    Button("Add Connection", systemImage: "network.badge.shield.half.filled") { router.showAddConnection = true }
                }
            }
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New VM", systemImage: "plus") { router.showNewVM = true }
                    .disabled(!app.connections.contains { $0.status == .connected })
                    .help("Create a new virtual machine")
            }
        }
        .sheet(isPresented: $router.showAddConnection) { AddConnectionSheet() }
        .sheet(isPresented: $router.showNewVM) { NewVMSheet(initial: app.selectedConnection) }
        .sheet(item: $sheetTarget) { target in
            switch target {
            case .clone(let c, let u): CloneSheet(connection: c, uuid: u)
            case .migrate(let c, let u): MigrateSheet(connection: c, uuid: u)
            case .delete(let c, let u): DeleteVMSheet(connection: c, uuid: u) { app.selection = .connection(c.id) }
            }
        }
        .confirmationDialog(confirmText, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let (c, d, a) = confirm {
                Button(a.title, role: a.isDestructive ? .destructive : nil) { c.perform(a, on: d.uuid) }
            }
        }
        .confirmationDialog("This will remove the connection:\n\n\(removingConnection?.uri ?? "")\n\nAre you sure?",
                            isPresented: Binding(get: { removingConnection != nil }, set: { if !$0 { removingConnection = nil } })) {
            Button("Remove", role: .destructive) { if let c = removingConnection { app.remove(c.id) } }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { app.connections.forEach { $0.lastError = nil } }
        } message: {
            Text(app.connections.compactMap(\.lastError).first ?? "")
        }
    }

    private var confirmText: String {
        guard let (_, d, a) = confirm else { return "" }
        return a.isDestructive
            ? "Are you sure you want to \(a.title.lowercased()) '\(d.name)'? This may cause data loss."
            : "Are you sure you want to \(a.title.lowercased()) '\(d.name)'?"
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) },
                set: { if $0 { collapsed.remove(id) } else { collapsed.insert(id) } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { app.connections.contains { $0.lastError != nil } },
                set: { if !$0 { app.connections.forEach { $0.lastError = nil } } })
    }

    @ViewBuilder private var detail: some View {
        if let (conn, d) = app.selectedDomain {
            VMView(connection: conn, uuid: d.uuid, initialTab: .details)
                .id(d.uuid)
        } else if let conn = app.selectedConnection {
            ConnectionDetailsView(connection: conn).id(conn.id)
        } else {
            ContentUnavailableView("No Selection", systemImage: "server.rack",
                                   description: Text("Select a connection or virtual machine in the sidebar."))
        }
    }

    private func request(_ c: ConnectionModel, _ d: DomainSummary, _ a: DomainAction) {
        let p = Preferences.shared
        let ask = switch a {
        case .forceOff, .reset: p.confirmForceOff
        case .shutdown, .reboot, .save: p.confirmPowerOff
        case .pause: p.confirmPause
        default: false
        }
        if ask { confirm = (c, d, a) } else { c.perform(a, on: d.uuid) }
    }

    @ViewBuilder private func menu(for item: SidebarItem) -> some View {
        switch item {
        case .domain(let cid, let uuid):
            if let c = app.connection(cid), let d = c.domain(uuid) {
                Button("Run") { request(c, d, .start) }.disabled(!DomainAction.start.isAvailable(for: d.state))
                if d.state == .paused {
                    Button("Resume") { request(c, d, .resume) }
                } else {
                    Button("Pause") { request(c, d, .pause) }.disabled(!DomainAction.pause.isAvailable(for: d.state))
                }
                Menu("Shut Down") {
                    ForEach(DomainAction.shutdownMenu, id: \.self) { a in
                        Button(a.title) { request(c, d, a) }.disabled(!a.isAvailable(for: d.state))
                    }
                }
                Divider()
                Button("Clone…") { sheetTarget = .clone(c, uuid) }
                Button("Migrate…") { sheetTarget = .migrate(c, uuid) }
                Button("Delete…", role: .destructive) { sheetTarget = .delete(c, uuid) }
                Divider()
                Button("Open") { openWindow(id: "vm", value: VMTarget(connectionID: cid, domainUUID: uuid, tab: .console)) }
            }
        case .connection(let cid):
            if let c = app.connection(cid) {
                Button("New Virtual Machine…") { app.selection = .connection(cid); router.showNewVM = true }
                    .disabled(c.status != .connected)
                if c.status == .connected || c.status == .connecting {
                    Button("Disconnect") { c.disconnect() }.disabled(c.status == .connecting)
                } else {
                    Button("Connect") { c.connect() }
                }
                Divider()
                Button("Delete", role: .destructive) { removingConnection = c }.disabled(c.status == .connected)
                Divider()
                Button("Details") { app.selection = .connection(cid) }
            }
        }
    }
}

struct DomainRow: View {
    let domain: DomainSummary
    let history: [StatsPoint]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(domain.state.isActive ? (domain.state == .paused ? Color.orange : .green) : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(domain.name).lineLimit(1)
                Text(domain.state.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if domain.state.isActive, Preferences.shared.showCPUColumn, history.count > 1 {
                Chart(history) { p in
                    AreaMark(x: .value("t", p.time), y: .value("CPU", p.cpuPercent))
                        .foregroundStyle(.green.opacity(0.35))
                    LineMark(x: .value("t", p.time), y: .value("CPU", p.cpuPercent))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                .chartYScale(domain: 0 ... 100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 56, height: 20)
                .help(String(format: "CPU %.0f%%", domain.cpuPercent))
            }
        }
    }

    private var icon: String {
        switch domain.state {
        case .running, .blocked: "play.circle.fill"
        case .paused, .suspended: "pause.circle.fill"
        case .crashed: "exclamationmark.octagon.fill"
        default: "stop.circle"
        }
    }
}

struct ConnectionHeader: View {
    let connection: ConnectionModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connection.isLocal ? "laptopcomputer" : "server.rack")
            Text(label).fontWeight(.medium).lineLimit(1)
            Circle().fill(color).frame(width: 7, height: 7)
            if connection.status == .connecting { ProgressView().controlSize(.mini) }
        }
        .help(connection.status == .connected ? connection.uri : "\(connection.uri) (Double click to connect)")
    }

    private var label: String {
        switch connection.status {
        case .disconnected, .failed: "\(connection.name) - Not Connected"
        case .connecting: "\(connection.name) - Connecting…"
        case .connected: connection.name
        }
    }

    private var color: Color {
        switch connection.status {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .gray
        case .failed: .red
        }
    }
}
