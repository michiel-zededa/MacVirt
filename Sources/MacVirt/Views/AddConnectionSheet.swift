// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct AddConnectionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case ssh = "Remote host (SSH)"
        case local = "This Mac (QEMU)"
        case custom = "Custom URI"
        var id: Self { self }
    }

    @StateVar private var kind = Kind.ssh
    @StateVar private var name = ""
    @StateVar private var user = NSUserName()
    @StateVar private var host = ""
    @StateVar private var port = ""
    @StateVar private var systemMode = true
    @StateVar private var customURI = "qemu+tcp://host/system"

    private var uri: String {
        switch kind {
        case .local: return BundledRuntime.localURI
        case .custom: return customURI.trimmingCharacters(in: .whitespaces)
        case .ssh:
            let u = user.isEmpty ? "" : "\(user)@"
            let p = port.isEmpty ? "" : ":\(port)"
            return "qemu+ssh://\(u)\(host)\(p)/\(systemMode ? "system" : "session")"
        }
    }

    private var isValid: Bool {
        switch kind {
        case .local: true
        case .ssh: !host.isEmpty && (port.isEmpty || Int(port) != nil)
        case .custom: URLComponents(string: customURI)?.scheme != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                switch kind {
                case .ssh:
                    TextField("Host", text: $host, prompt: Text("kvm-host.example.com"))
                    TextField("User", text: $user)
                    TextField("SSH port", text: $port, prompt: Text("22"))
                    Picker("Mode", selection: $systemMode) {
                        Text("System (qemu:///system)").tag(true)
                        Text("Session (qemu:///session)").tag(false)
                    }
                    Text("Uses /usr/bin/ssh. Key-based login is recommended; passwords and host keys are asked for in a dialog.")
                        .font(.caption).foregroundStyle(.secondary)
                case .local:
                    Text("Runs VMs on this Mac with the bundled QEMU and libvirt, using Apple's Hypervisor framework.")
                        .font(.caption).foregroundStyle(.secondary)
                case .custom:
                    TextField("URI", text: $customURI)
                }
                TextField("Name", text: $name, prompt: Text(defaultName))
                LabeledContent("URI", value: uri).textSelection(.enabled).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    app.add(name: name.isEmpty ? defaultName : name, uri: uri)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 480)
    }

    private var defaultName: String {
        switch kind {
        case .local: "Local (QEMU)"
        case .ssh: host.isEmpty ? "Remote" : host
        case .custom: URLComponents(string: customURI)?.host ?? "Custom"
        }
    }
}
