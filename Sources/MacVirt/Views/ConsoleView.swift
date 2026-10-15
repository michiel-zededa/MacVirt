// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

/// Owns the RFB client for one console window.
@MainActor @Observable
final class ConsoleSession: RFBClientDelegate {
    enum Phase: Equatable { case connecting, connected, failed(String) }

    var phase: Phase = .connecting
    var framebufferSize = CGSize(width: 1024, height: 768)
    @ObservationIgnored let view = VNCView()
    @ObservationIgnored private var client: RFBClient?

    func connect(connection: ConnectionModel, domainUUID: String) {
        stop()
        phase = .connecting
        let uri = connection.uri
        Task {
            do {
                let details = try await connection.liveDetails(uuid: domainUUID)
                guard let vnc = details.graphics.first(where: { $0.type == "vnc" }) else {
                    throw LibvirtError(message: details.graphics.isEmpty
                        ? "This VM has no graphical display."
                        : "Only VNC displays are supported (found \(details.graphics.map(\.type).joined(separator: ", "))).")
                }
                let transport = try await Task.detached { try VNCTransport.make(libvirtURI: uri, graphics: vnc) }.value
                let client = RFBClient(transport: transport)
                client.delegate = self
                self.client = client
                view.client = client
                client.start()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        client?.delegate = nil
        client?.stop()
        client = nil
    }

    nonisolated func rfbDidConnect(name: String, width: Int, height: Int) {
        MainActor.assumeIsolated {
            phase = .connected
            framebufferSize = CGSize(width: width, height: height)
            view.window?.makeFirstResponder(view)
        }
    }

    nonisolated func rfbFramebufferChanged() {
        MainActor.assumeIsolated { view.framebufferChanged() }
    }

    nonisolated func rfbDidDisconnect(error: String?) {
        MainActor.assumeIsolated { phase = .failed(error ?? "Disconnected") }
    }

    nonisolated func rfbNeedsPassword() -> String? {
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = "VNC Password"
            alert.informativeText = "The console of this VM is protected with a password."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
    }
}

private struct VNCViewRepresentable: NSViewRepresentable {
    let view: VNCView
    func makeNSView(context: Context) -> VNCView { view }
    func updateNSView(_ nsView: VNCView, context: Context) {}
}

struct ConsoleView: View {
    let target: ConsoleTarget
    @StateVar private var session = ConsoleSession()
    private var app: AppModel { .shared }

    private var connection: ConnectionModel? { app.connection(target.connectionID) }
    private var domain: DomainSummary? { connection?.domains.first { $0.uuid == target.domainUUID } }

    var body: some View {
        ZStack {
            VNCViewRepresentable(view: session.view)
                .aspectRatio(session.framebufferSize, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            overlay
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(domain?.name ?? "Console")
        .navigationSubtitle(connection?.name ?? "")
        .toolbar {
            if let connection, let domain {
                ToolbarItemGroup {
                    ForEach([DomainAction.start, .pause, .resume, .shutdown], id: \.self) { action in
                        if action.isAvailable(for: domain.state) {
                            Button(action.title, systemImage: action.symbol) {
                                connection.perform(action, on: domain.uuid)
                            }
                        }
                    }
                    Menu("Send Key", systemImage: "keyboard") {
                        Button("Ctrl+Alt+Delete") { session.view.sendCtrlAltDel() }
                    }
                    Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") { reconnect() }
                }
            }
        }
        .onAppear(perform: reconnect)
        .onDisappear { session.stop() }
        .onChange(of: domain?.state) { old, new in
            // Reconnect when the VM (re)starts while the console is open.
            if let new, new.isActive, old.map({ !$0.isActive }) ?? true { reconnect() }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch session.phase {
        case .connected: EmptyView()
        case .connecting:
            ProgressView("Connecting to console…").padding().glassEffect()
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle)
                Text(domain?.state.isActive == false ? "The virtual machine is not running." : message)
                    .multilineTextAlignment(.center)
                if domain?.state.isActive == false, let connection, let domain {
                    Button("Run", systemImage: "play.fill") { connection.perform(.start, on: domain.uuid) }
                        .buttonStyle(.glassProminent)
                } else {
                    Button("Reconnect") { reconnect() }
                }
            }
            .padding(24)
            .glassEffect(in: .rect(cornerRadius: 16))
        }
    }

    private func reconnect() {
        guard let connection, let domain, domain.state.isActive else {
            session.stop()
            session.phase = .failed("The virtual machine is not running.")
            return
        }
        session.connect(connection: connection, domainUUID: target.domainUUID)
    }
}
