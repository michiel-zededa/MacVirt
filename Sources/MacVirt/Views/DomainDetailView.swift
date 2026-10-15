// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct DomainDetailView: View {
    let connection: ConnectionModel
    let domain: DomainSummary

    @StateVar private var tab = 0
    @StateVar private var details: DomainDetails?
    @StateVar private var xml = ""
    @StateVar private var originalXML = ""
    @StateVar private var xmlError: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Overview").tag(0)
                Text("XML").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.vertical, 10)

            if tab == 0 { overview } else { xmlEditor }
        }
        .navigationTitle(domain.name)
        .navigationSubtitle(domain.state.label)
        .task(id: domain.state) { await load() }
    }

    private var overview: some View {
        Form {
            Section("General") {
                LabeledContent("Name", value: domain.name)
                LabeledContent("UUID", value: domain.uuid).textSelection(.enabled)
                LabeledContent("State", value: domain.state.label)
                LabeledContent("Persistent", value: domain.persistent ? "Yes" : "No")
                if let details {
                    LabeledContent("Hypervisor", value: "\(details.hypervisor.uppercased()) · \(details.arch) · \(details.machine)")
                }
            }
            Section("Resources") {
                LabeledContent("vCPUs", value: "\(domain.vcpus)")
                LabeledContent("Memory", value: "\(domain.memoryMiB) MiB")
                if domain.state.isActive {
                    LabeledContent("CPU usage") {
                        ProgressView(value: domain.cpuPercent, total: 100) {
                            Text(String(format: "%.0f%%", domain.cpuPercent))
                        }
                        .frame(width: 180)
                    }
                }
            }
            if let details {
                Section("Storage") {
                    ForEach(details.disks, id: \.self) { disk in
                        LabeledContent("\(disk.device == "cdrom" ? "CD-ROM" : "Disk") \(disk.target) (\(disk.bus))") {
                            Text(disk.source.isEmpty ? "Empty" : disk.source)
                                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Section("Network") {
                    ForEach(details.interfaces, id: \.self) { nic in
                        LabeledContent("\(nic.type) \(nic.source)") { Text("\(nic.model) · \(nic.mac)").textSelection(.enabled) }
                    }
                }
                Section("Display") {
                    ForEach(details.graphics, id: \.self) { g in
                        LabeledContent(g.type.uppercased(), value: g.port > 0 ? "\(g.listen):\(g.port)" : "Not active")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var xmlEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $xml)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
            HStack {
                if let xmlError {
                    Label(xmlError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(3)
                } else if domain.state.isActive {
                    Text("Changes apply the next time the VM starts.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { xml = originalXML; xmlError = nil }.disabled(xml == originalXML)
                Button("Apply") { apply() }.buttonStyle(.glassProminent).disabled(xml == originalXML)
            }
        }
        .padding([.horizontal, .bottom])
    }

    private func load() async {
        details = try? await connection.liveDetails(uuid: domain.uuid)
        if let x = try? await connection.domainXML(uuid: domain.uuid), xml == originalXML {
            xml = x
            originalXML = x
        }
    }

    private func apply() {
        Task {
            do {
                try await connection.define(xml: xml)
                originalXML = xml
                xmlError = nil
                await load()
            } catch {
                xmlError = error.localizedDescription
            }
        }
    }
}
