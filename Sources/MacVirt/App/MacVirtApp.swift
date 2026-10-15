// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct MacVirtApp: App {
    @StateVar private var app = AppModel.shared

    var body: some Scene {
        Window("MacVirt", id: "main") {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewVMCommand()
                AddConnectionCommand()
            }
        }

        WindowGroup("Console", id: "console", for: ConsoleTarget.self) { $target in
            if let target {
                ConsoleView(target: target)
            }
        }
        .defaultSize(width: 1040, height: 820)

        Window("About MacVirt", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
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
            Text("A native macOS virtual machine manager for libvirt,\ninspired by virt-manager.")
                .multilineTextAlignment(.center)
            Text("Bundles libvirt \(Libvirt.version) and QEMU. Licensed under GPL-2.0-or-later.")
                .font(.caption).foregroundStyle(.secondary)
            Link("github.com/michiel-zededa/MacVirt", destination: URL(string: "https://github.com/michiel-zededa/MacVirt")!)
                .font(.caption)
        }
        .padding(28)
        .frame(width: 380)
    }
}
