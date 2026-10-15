// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @StateVar private var router = SheetRouter.shared
    @StateVar private var deleting: (ConnectionModel, DomainSummary)?
    @StateVar private var collapsed: Set<UUID> = []

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selection) {
                ForEach(app.connections) { conn in
                    DisclosureGroup(isExpanded: expandedBinding(conn.id)) {
                        ForEach(conn.domains) { d in
                            DomainRow(domain: d)
                                .tag(SidebarItem.domain(conn.id, d.uuid))
                                .contextMenu { domainMenu(conn, d) }
                        }
                    } label: {
                        ConnectionHeader(connection: conn)
                            .tag(SidebarItem.connection(conn.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button("Add Connection", systemImage: "network.badge.shield.half.filled") {
                        router.showAddConnection = true
                    }
                }
            }
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New VM", systemImage: "plus") { router.showNewVM = true }
                    .disabled(!app.connections.contains { $0.status == .connected })
                if let (conn, d) = app.selectedDomain {
                    Button("Open Console", systemImage: "display") {
                        openWindow(id: "console", value: ConsoleTarget(connectionID: conn.id, domainUUID: d.uuid))
                    }
                    ForEach(DomainAction.allCases, id: \.self) { action in
                        if action.isAvailable(for: d.state) {
                            Button(action.title, systemImage: action.symbol) { conn.perform(action, on: d.uuid) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $router.showAddConnection) { AddConnectionSheet() }
        .sheet(isPresented: $router.showNewVM) { NewVMSheet(initial: app.selectedConnection) }
        .confirmationDialog(
            "Delete “\(deleting?.1.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            if let (conn, d) = deleting {
                Button("Delete VM and Disk Images", role: .destructive) { delete(conn, d, disks: true) }
                Button("Delete VM, Keep Disks", role: .destructive) { delete(conn, d, disks: false) }
            }
        } message: {
            Text("A running VM will be powered off first. This cannot be undone.")
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { app.connections.forEach { $0.lastError = nil } }
        } message: {
            Text(app.connections.compactMap(\.lastError).first ?? "")
        }
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
            DomainDetailView(connection: conn, domain: d)
                .id(d.uuid)
        } else if let conn = app.selectedConnection {
            ConnectionDetailView(connection: conn)
        } else {
            ContentUnavailableView("No Selection", systemImage: "server.rack",
                                   description: Text("Select a connection or virtual machine in the sidebar."))
        }
    }

    @ViewBuilder private func domainMenu(_ conn: ConnectionModel, _ d: DomainSummary) -> some View {
        Button("Open Console") {
            openWindow(id: "console", value: ConsoleTarget(connectionID: conn.id, domainUUID: d.uuid))
        }
        Divider()
        ForEach(DomainAction.allCases, id: \.self) { action in
            if action.isAvailable(for: d.state) {
                Button(action.title) { conn.perform(action, on: d.uuid) }
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = (conn, d) }
    }

    private func delete(_ conn: ConnectionModel, _ d: DomainSummary, disks: Bool) {
        Task {
            do { try await conn.delete(uuid: d.uuid, removeDisks: disks) }
            catch { conn.lastError = error.localizedDescription }
        }
        deleting = nil
    }
}

struct DomainRow: View {
    let domain: DomainSummary

    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(domain.state.isActive ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(domain.name)
                Text(domain.state.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if domain.state.isActive {
                CPUGauge(percent: domain.cpuPercent)
            }
        }
    }
}

struct CPUGauge: View {
    let percent: Double
    var body: some View {
        Gauge(value: percent, in: 0 ... 100) { EmptyView() }
            .gaugeStyle(.accessoryCircularCapacity)
            .scaleEffect(0.45)
            .frame(width: 24, height: 24)
            .help(String(format: "CPU %.0f%%", percent))
    }
}

struct ConnectionHeader: View {
    @Environment(AppModel.self) private var app
    let connection: ConnectionModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connection.isLocal ? "laptopcomputer" : "server.rack")
            Text(connection.name).fontWeight(.medium)
            Circle().fill(color).frame(width: 7, height: 7)
            if connection.status == .connecting { ProgressView().controlSize(.mini) }
        }
        .contextMenu {
            if connection.status == .connected {
                Button("Disconnect") { connection.disconnect() }
            } else {
                Button("Connect") { connection.connect() }
            }
            Divider()
            Button("Remove Connection", role: .destructive) { app.remove(connection.id) }
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

struct ConnectionDetailView: View {
    @Environment(AppModel.self) private var app
    let connection: ConnectionModel

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Name", value: connection.name)
                LabeledContent("URI", value: connection.uri).textSelection(.enabled)
                LabeledContent("Status") {
                    switch connection.status {
                    case .connected: Text("Connected")
                    case .connecting: Text("Connecting…")
                    case .disconnected: Text("Disconnected")
                    case .failed(let msg): Text(msg).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if connection.status == .connected {
                    LabeledContent("Host", value: connection.hostDescription)
                    LabeledContent("Virtual machines", value: "\(connection.domains.count) (\(connection.domains.filter { $0.state.isActive }.count) running)")
                }
                if connection.isLocal {
                    LabeledContent("Bundled libvirt", value: Libvirt.version)
                }
            }
            Section {
                HStack {
                    if connection.status == .connected {
                        Button("Disconnect") { connection.disconnect() }
                    } else {
                        Button("Connect") { connection.connect() }.buttonStyle(.glassProminent)
                    }
                    Spacer()
                    Button("Remove Connection", role: .destructive) { app.remove(connection.id) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(connection.name)
    }
}
