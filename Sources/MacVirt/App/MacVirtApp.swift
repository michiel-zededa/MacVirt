// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct MacVirtApp: App {
    @StateVar private var app = AppModel.shared

    var body: some Scene {
        Window("MacVirt", id: "main") {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewVMCommand()
                AddConnectionCommand()
            }
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
        }

        WindowGroup("Virtual Machine", id: "vm", for: VMTarget.self) { $target in
            if let target, let conn = app.connection(target.connectionID) {
                VMView(connection: conn, uuid: target.domainUUID, initialTab: target.tab)
                    .environment(app)
            }
        }
        .defaultSize(width: 1100, height: 800)

        Window("About MacVirt", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            PreferencesView()
        }
    }
}

/// Lets menu commands open sheets that live in the main window.
@MainActor @Observable
final class SheetRouter {
    static let shared = SheetRouter()
    var showNewVM = false
    var showAddConnection = false
}

private struct NewVMCommand: View {
    var body: some View {
        Button("New Virtual Machine…") { SheetRouter.shared.showNewVM = true }
            .keyboardShortcut("n")
    }
}

private struct AddConnectionCommand: View {
    var body: some View {
        Button("Add Connection…") { SheetRouter.shared.showAddConnection = true }
            .keyboardShortcut("n", modifiers: [.command, .shift])
    }
}

private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About MacVirt") { openWindow(id: "about") }
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("MacVirt").font(.title).bold()
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("A native macOS virtual machine manager for libvirt.\nBased on the functionality of virt-manager,\nwritten from scratch for macOS in Swift.")
                .multilineTextAlignment(.center)
            Text("Bundles libvirt \(Libvirt.version) and QEMU. Licensed under GPL-2.0-or-later.")
                .font(.caption).foregroundStyle(.secondary)
            Link("github.com/michiel-zededa/MacVirt", destination: URL(string: "https://github.com/michiel-zededa/MacVirt")!)
                .font(.caption)
        }
        .padding(28)
        .frame(width: 400)
    }
}

struct PreferencesView: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        TabView {
            Form {
                Toggle("Enable XML editing", isOn: $prefs.xmlEditingEnabled)
                Picker("Storage format for new disks", selection: $prefs.defaultStorageFormat) {
                    Text("QCOW2").tag("qcow2")
                    Text("Raw").tag("raw")
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Update status every", selection: $prefs.pollInterval) {
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Toggle("Show CPU usage graph in the VM list", isOn: $prefs.showCPUColumn)
                Text("The poll interval applies to connections opened after the change.").font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Polling", systemImage: "chart.xyaxis.line") }

            Form {
                Picker("Graphical console scaling", selection: $prefs.consoleScaling) {
                    Text("Never").tag(0)
                    Text("Only when fullscreen").tag(1)
                    Text("Always").tag(2)
                }
                Toggle("Automatically connect to the console", isOn: $prefs.consoleAutoconnect)
            }
            .tabItem { Label("Console", systemImage: "display") }

            Form {
                Toggle("Force Off / Force Reset", isOn: $prefs.confirmForceOff)
                Toggle("Shut Down / Reboot / Save", isOn: $prefs.confirmPowerOff)
                Toggle("Pause", isOn: $prefs.confirmPause)
                Toggle("Device removal", isOn: $prefs.confirmRemoveDevice)
                Toggle("Deleting storage", isOn: $prefs.confirmDeleteStorage)
            }
            .tabItem { Label("Confirmations", systemImage: "questionmark.circle") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
    }
}
