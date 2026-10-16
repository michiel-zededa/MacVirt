// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

/// Owns the RFB client for one graphical console.
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
                        : "MacVirt supports VNC displays; this VM only has \(details.graphics.map { Pretty.graphics($0.type) }.joined(separator: ", ")). Add a VNC display in the Details tab, or use a serial console.")
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
        view.client = nil
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

    /// Saves the current framebuffer as PNG.
    func saveScreenshot(name: String) {
        guard let image = view.image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot_\(name)_\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")).png"
        guard panel.runModal() == .OK, let url = panel.url,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

private struct VNCViewRepresentable: NSViewRepresentable {
    let view: VNCView
    let scale: Bool
    func makeNSView(context: Context) -> VNCView { view }
    func updateNSView(_ nsView: VNCView, context: Context) { nsView.scaleToFit = scale }
}

struct GraphicalConsoleView: View {
    let connection: ConnectionModel
    let uuid: String
    let session: ConsoleSession
    let scale: Bool

    private var domain: DomainSummary? { connection.domain(uuid) }

    var body: some View {
        ZStack {
            if scale {
                VNCViewRepresentable(view: session.view, scale: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VNCViewRepresentable(view: session.view, scale: false)
                        .frame(width: session.framebufferSize.width, height: session.framebufferSize.height)
                }
            }
            overlay
        }
        .background(.black)
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
                if domain?.state.isActive == false, let domain {
                    Button("Run", systemImage: "play.fill") { connection.perform(.start, on: domain.uuid) }
                        .buttonStyle(.glassProminent)
                } else {
                    Button("Reconnect") { reconnect() }
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
            .glassEffect(in: .rect(cornerRadius: 16))
        }
    }

    func reconnect() {
        guard let domain, domain.state.isActive else {
            session.stop()
            session.phase = .failed("The virtual machine is not running.")
            return
        }
        session.connect(connection: connection, domainUUID: uuid)
    }
}
