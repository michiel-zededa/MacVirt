// SPDX-License-Identifier: GPL-2.0-or-later
// Connection Details: Overview, Virtual Networks and Storage.

import Charts
import SwiftUI

enum HostTab: String, CaseIterable, Codable {
    case overview = "Overview", networks = "Virtual Networks", storage = "Storage"
}

struct ConnectionDetailsView: View {
    @Environment(AppModel.self) private var app
    let connection: ConnectionModel
    @StateVar private var tab: HostTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(HostTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(.vertical, 10)
            Divider()
            if connection.status != .connected && tab != .overview {
                ContentUnavailableView("Connection not active.", systemImage: "bolt.horizontal.circle")
            } else {
                switch tab {
                case .overview: HostOverview(connection: connection)
                case .networks: NetworksView(connection: connection).id(connection.id)
                case .storage: StorageManagerView(connection: connection).id(connection.id)
                }
            }
        }
        .navigationTitle("\(connection.name) — Connection Details")
    }
}

struct HostOverview: View {
    @Environment(AppModel.self) private var app
    @Bindable var connection: ConnectionModel

    private struct Point: Identifiable { var id: Date { t }; var t: Date; var cpu: Double; var mem: Double }

    /// Host CPU/memory used by running VMs, derived from per-VM history.
    private var points: [Point] {
        let history = connection.history
        guard let longest = history.values.max(by: { $0.count < $1.count }) else { return [] }
        let hostCPUs = Double(max(connection.nodeInfo?.cpus ?? 1, 1))
        let hostMiB = Double(max((connection.nodeInfo?.memoryKiB ?? 1024) / 1024, 1))
        return longest.indices.map { i in
            var cpu = 0.0, mem = 0.0
            for (uuid, series) in history {
                let j = i - (longest.count - series.count)
                guard j >= 0, let vm = connection.domain(uuid) else { continue }
                cpu += series[j].cpuPercent * Double(vm.vcpus)
                mem += Double(vm.memoryMiB)
            }
            return Point(t: longest[i].time, cpu: min(100, cpu / hostCPUs), mem: min(100, mem / hostMiB * 100))
        }
    }

    var body: some View {
        Form {
            Section("Basic details") {
                TextField("Name", text: $connection.name)
                    .onSubmit { app.persist() }
                LabeledContent("Libvirt URI") { Text(connection.uri).textSelection(.enabled) }
                Toggle("Autoconnect", isOn: $connection.autoconnect)
                    .onChange(of: connection.autoconnect) { app.persist() }
                LabeledContent("Status") {
                    switch connection.status {
                    case .connected: Text("Active")
                    case .connecting: Text("Connecting…")
                    case .disconnected: Text("Disconnected")
                    case .failed(let msg): Text(msg).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if connection.status == .connected {
                    LabeledContent("Hostname", value: connection.hostname)
                    LabeledContent("Hypervisor", value: connection.hypervisor)
                    LabeledContent("Libvirt", value: connection.libvirtVersion)
                    if let n = connection.nodeInfo {
                        LabeledContent("CPUs", value: "\(n.cpus) × \(n.model)\(n.mhz > 0 ? " @ \(n.mhz) MHz" : "")")
                        LabeledContent("Memory", value: Pretty.bytes(UInt64(n.memoryKiB) * 1024))
                    }
                }
                HStack {
                    if connection.status == .connected {
                        Button("Disconnect") { connection.disconnect() }
                    } else {
                        Button("Connect") { connection.connect() }.buttonStyle(.glassProminent)
                    }
                }
            }
            if connection.status == .connected {
                let pts = points
                Section("CPU usage") {
                    Text(String(format: "%.0f %%", pts.last?.cpu ?? 0)).font(.caption).foregroundStyle(.secondary)
                    Chart(pts) { AreaMark(x: .value("t", $0.t), y: .value("CPU", $0.cpu)).opacity(0.4) }
                        .chartYScale(domain: 0 ... 100).chartXAxis(.hidden).frame(height: 70)
                }
                Section("Memory usage") {
                    let used = connection.domains.filter { $0.state.isActive }.reduce(0) { $0 + $1.memoryMiB }
                    Text("\(Pretty.bytes(UInt64(used) << 20)) of \(Pretty.bytes(UInt64(connection.nodeInfo?.memoryKiB ?? 0) * 1024))")
                        .font(.caption).foregroundStyle(.secondary)
                    Chart(pts) { AreaMark(x: .value("t", $0.t), y: .value("Mem", $0.mem)).opacity(0.4).foregroundStyle(.orange) }
                        .chartYScale(domain: 0 ... 100).chartXAxis(.hidden).frame(height: 70)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Virtual networks

struct NetworkRow: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var active: Bool
    var autostart: Bool
    var bridge: String
    var xml: String

    private var root: XMLElement? { (try? XMLDocument(xmlString: xml))?.rootElement() }
    var domainName: String { root?.child("domain")?.attr("name") ?? "" }

    var forwarding: String {
        guard let f = root?.child("forward"), let mode = f.attr("mode") else { return "Isolated network" }
        let dev = f.attr("dev")
        switch mode {
        case "nat": return dev.map { "NAT to \($0)" } ?? "NAT"
        case "route": return dev.map { "Route to \($0)" } ?? "Routed network"
        default: return "\(mode.capitalized) network"
        }
    }

    func ip(v6: Bool) -> (network: String, dhcp: String)? {
        guard let ip = root?.elements(forName: "ip").first(where: { ($0.attr("family") == "ipv6") == v6 }),
              let addr = ip.attr("address") else { return nil }
        var prefix = ip.attr("prefix") ?? ""
        if prefix.isEmpty, let mask = ip.attr("netmask") {
            prefix = String(mask.split(separator: ".").compactMap { UInt8($0) }.reduce(0) { $0 + $1.nonzeroBitCount })
        }
        let range = ip.child("dhcp")?.child("range")
        let dhcp = range.map { "\($0.attr("start") ?? "") - \($0.attr("end") ?? "")" } ?? "Disabled"
        return (v6 ? "\(addr)/\(prefix)" : Self.networkAddress(addr, prefix: Int(prefix) ?? 24), dhcp)
    }

    static func networkAddress(_ addr: String, prefix: Int) -> String {
        let parts = addr.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return "\(addr)/\(prefix)" }
        let v = parts.reduce(0) { $0 << 8 | $1 }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        let n = v & mask
        return "\(n >> 24).\((n >> 16) & 255).\((n >> 8) & 255).\(n & 255)/\(prefix)"
    }
}

struct NetworksView: View {
    let connection: ConnectionModel
    @StateVar private var networks: [NetworkRow] = []
    @StateVar private var selection: String?
    @StateVar private var error: String?
    @StateVar private var creating = false
    @StateVar private var confirmDelete = false
    @StateVar private var showXML = false

    private var selected: NetworkRow? { networks.first { $0.name == selection } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(networks, selection: $selection) { n in
                    Label(n.name, systemImage: "network").opacity(n.active ? 1 : 0.5).tag(n.name)
                }
                HStack(spacing: 2) {
                    Button("Add Network", systemImage: "plus") { creating = true }
                    Button("Start Network", systemImage: "play.fill") { act { try $0.start() } }.disabled(selected?.active ?? true)
                    Button("Stop Network", systemImage: "stop.fill") { act { try $0.stop() } }.disabled(!(selected?.active ?? false))
                    Button("Delete Network", systemImage: "trash") { confirmDelete = true }.disabled(selected?.active ?? true)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)

            Group {
                if let error {
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let n = selected {
                    Form {
                        Section {
                            LabeledContent("Name", value: n.name)
                            LabeledContent("Device", value: n.bridge)
                            LabeledContent("State") { Label(n.active ? "Active" : "Inactive", systemImage: n.active ? "play.circle.fill" : "stop.circle") }
                            Toggle("Autostart on boot", isOn: Binding(get: { n.autostart }, set: { on in act { try $0.setAutostart(on) } }))
                            if !n.domainName.isEmpty { LabeledContent("Domain", value: n.domainName) }
                        }
                        if let v4 = n.ip(v6: false) {
                            Section("IPv4 configuration") {
                                LabeledContent("Network", value: v4.network)
                                LabeledContent("DHCP range", value: v4.dhcp)
                                LabeledContent("Forwarding", value: n.forwarding)
                            }
                        }
                        if let v6 = n.ip(v6: true) {
                            Section("IPv6 configuration") {
                                LabeledContent("Network", value: v6.network)
                                LabeledContent("DHCP range", value: v6.dhcp)
                                LabeledContent("Forwarding", value: "Routed network")
                            }
                        }
                        Section { HStack { Spacer(); Button("Edit XML…") { showXML = true } } }
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("No virtual network selected.", systemImage: "network")
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await load() }
        .sheet(isPresented: $creating) { CreateNetworkSheet(connection: connection, existing: networks.map(\.name)) { n in Task { await load(select: n) } } }
        .sheet(isPresented: $showXML) {
            if let n = selected {
                XMLEditorSheet(title: "Network \(n.name)", xml: n.xml) { xml in
                    try await connection.withConnection { try $0.defineNetwork(xml: xml) }
                    await load()
                }
            }
        }
        .confirmationDialog("Are you sure you want to permanently delete the network \(selected?.name ?? "")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { act { try $0.undefine() } }
        }
    }

    private func load(select: String? = nil) async {
        do {
            networks = try await connection.withConnection { conn in
                try conn.networks().map { n in
                    NetworkRow(name: n.name, active: n.isActive, autostart: n.autostart, bridge: n.bridgeName, xml: (try? n.xml()) ?? "")
                }
            }.sorted { $0.name < $1.name }
            error = nil
            if let select { selection = select } else if selected == nil { selection = networks.first?.name }
        } catch {
            self.error = "Libvirt connection does not support virtual network management.\n\(error.localizedDescription)"
        }
    }

    private func act(_ work: @escaping @Sendable (Network) throws -> Void) {
        guard let name = selection else { return }
        Task {
            do { try await connection.withConnection { try work(try $0.network(named: name)) } }
            catch { connection.lastError = error.localizedDescription }
            await load()
        }
    }
}

struct CreateNetworkSheet: View {
    let connection: ConnectionModel
    let existing: [String]
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateVar private var name = "network"
    @StateVar private var mode = "nat"
    @StateVar private var forwardDev = ""
    @StateVar private var ipv4 = true
    @StateVar private var ipv4Net = "192.168.100.0/24"
    @StateVar private var dhcp4 = true
    @StateVar private var dhcp4Start = "192.168.100.128"
    @StateVar private var dhcp4End = "192.168.100.254"
    @StateVar private var ipv6 = false
    @StateVar private var ipv6Net = ""
    @StateVar private var dhcp6 = false
    @StateVar private var dhcp6Start = ""
    @StateVar private var dhcp6End = ""
    @StateVar private var customDomain = false
    @StateVar private var domainName = ""
    @StateVar private var error: String?
    @StateVar private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Create virtual network") {
                    TextField("Name", text: $name)
                    Picker("Mode", selection: $mode) {
                        Text("NAT").tag("nat")
                        Text("Routed").tag("route")
                        Text("Open").tag("open")
                        Text("Isolated").tag("isolated")
                    }
                    if mode == "nat" || mode == "route" {
                        TextField("Forward to", text: $forwardDev, prompt: Text("Any physical device"))
                    }
                }
                Section("IPv4 configuration") {
                    Toggle("Enable IPv4", isOn: $ipv4)
                    if ipv4 {
                        TextField("Network", text: $ipv4Net).onChange(of: ipv4Net) { recomputeDHCP4() }
                        Toggle("Enable DHCPv4", isOn: $dhcp4)
                        if dhcp4 {
                            TextField("Start", text: $dhcp4Start)
                            TextField("End", text: $dhcp4End)
                        }
                    }
                }
                Section("IPv6 configuration") {
                    Toggle("Enable IPv6", isOn: $ipv6)
                    if ipv6 {
                        TextField("Network", text: $ipv6Net, prompt: Text("fd00:1::/64"))
                        Toggle("Enable DHCPv6", isOn: $dhcp6)
                        if dhcp6 {
                            TextField("Start", text: $dhcp6Start)
                            TextField("End", text: $dhcp6End)
                        }
                    }
                }
                Section("DNS domain name") {
                    Picker("", selection: $customDomain) {
                        Text("Use network name").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if customDomain { TextField("Domain", text: $domainName) }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Creating virtual network…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Finish") { create() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || busy)
            }
            .padding()
        }
        .frame(width: 520, height: 640)
        .onAppear {
            var n = "network", i = 1
            while existing.contains(n) { n = "network-\(i)"; i += 1 }
            name = n
        }
    }

    private func recomputeDHCP4() {
        let parts = ipv4Net.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix > 0, prefix < 31 else { return }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { return }
        let base = octets.reduce(0) { $0 << 8 | $1 } & (~UInt32(0) << (32 - UInt32(prefix)))
        let size = UInt32(1) << (32 - UInt32(prefix))
        func str(_ v: UInt32) -> String { "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }
        dhcp4Start = str(base + size / 2)
        dhcp4End = str(base + size - 2)
    }

    private var xml: String {
        var x = "<network><name>\(name.xmlEscaped)</name>"
        if mode != "isolated" {
            x += "<forward mode='\(mode)'\(forwardDev.isEmpty || !(mode == "nat" || mode == "route") ? "" : " dev='\(forwardDev.xmlEscaped)'")/>"
        }
        x += "<domain name='\((customDomain ? domainName : name).xmlEscaped)'/>"
        if ipv4 {
            let parts = ipv4Net.split(separator: "/")
            if parts.count == 2, let prefix = Int(parts[1]) {
                let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
                if octets.count == 4 {
                    let base = octets.reduce(0) { $0 << 8 | $1 } & (~UInt32(0) << (32 - UInt32(prefix)))
                    let gw = base + 1
                    let mask = ~UInt32(0) << (32 - UInt32(prefix))
                    func str(_ v: UInt32) -> String { "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }
                    x += "<ip address='\(str(gw))' netmask='\(str(mask))'>"
                    if dhcp4 { x += "<dhcp><range start='\(dhcp4Start.xmlEscaped)' end='\(dhcp4End.xmlEscaped)'/></dhcp>" }
                    x += "</ip>"
                }
            }
        }
        if ipv6, let slash = ipv6Net.firstIndex(of: "/") {
            let addr = String(ipv6Net[..<slash]), prefix = String(ipv6Net[ipv6Net.index(after: slash)...])
            let gw = addr.hasSuffix("::") ? addr + "1" : addr
            x += "<ip family='ipv6' address='\(gw.xmlEscaped)' prefix='\(prefix.xmlEscaped)'>"
            if dhcp6 { x += "<dhcp><range start='\(dhcp6Start.xmlEscaped)' end='\(dhcp6End.xmlEscaped)'/></dhcp>" }
            x += "</ip>"
        }
        return x + "</network>"
    }

    private func create() {
        guard !existing.contains(name), !name.contains("/") else {
            error = "Name '\(name)' already in use by another network."
            return
        }
        busy = true
        let xml = self.xml, name = self.name
        Task {
            do {
                try await connection.withConnection { conn in
                    let net = try conn.defineNetwork(xml: xml)
                    do {
                        try net.start()
                        try net.setAutostart(true)
                    } catch {
                        try? net.undefine()
                        throw error
                    }
                }
                onCreated(name)
                dismiss()
            } catch {
                self.error = "Error creating virtual network: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}
