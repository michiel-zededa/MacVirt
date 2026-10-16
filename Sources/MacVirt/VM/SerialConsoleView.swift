// SPDX-License-Identifier: GPL-2.0-or-later
// Text console for serial/console devices via virDomainOpenConsole.

import AppKit
import SwiftTerm
import SwiftUI

@MainActor @Observable
final class SerialSession {
    enum Phase: Equatable { case connecting, connected, failed(String) }

    var phase: Phase = .connecting
    @ObservationIgnored let terminal: TerminalView
    @ObservationIgnored private var stream: Stream?
    @ObservationIgnored private let bridge = TerminalBridge()

    init() {
        terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.terminalDelegate = bridge
        bridge.session = self
    }

    func connect(connection: ConnectionModel, uuid: String, alias: String?) {
        stop()
        phase = .connecting
        Task {
            do {
                let stream = try await connection.withConnection { conn in
                    try conn.domain(uuid: uuid).openConsole(device: alias, connection: conn)
                }
                self.stream = stream
                stream.start(onData: { [weak self] data in
                    DispatchQueue.main.async {
                        self?.terminal.feed(byteArray: ArraySlice([UInt8](data)))
                    }
                }, onClose: { [weak self] msg in
                    DispatchQueue.main.async { self?.phase = .failed(msg ?? "Console disconnected") }
                })
                phase = .connected
                terminal.window?.makeFirstResponder(terminal)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        let data = Data(bytes)
        let stream = self.stream
        DispatchQueue.global().async { stream?.send(data) }
    }

    func stop() {
        let s = stream
        stream = nil
        DispatchQueue.global().async { s?.close() }
    }
}

private final class TerminalBridge: NSObject, TerminalViewDelegate {
    weak var session: SerialSession?

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { session?.send(data) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private struct TerminalRepresentable: NSViewRepresentable {
    let view: TerminalView
    func makeNSView(context: Context) -> TerminalView { view }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

struct SerialConsoleView: View {
    let connection: ConnectionModel
    let uuid: String
    /// Device alias (e.g. "serial0"), or nil for the default console.
    let alias: String?
    @StateVar private var session = SerialSession()

    private var running: Bool { connection.domain(uuid)?.state.isActive ?? false }

    var body: some View {
        ZStack {
            TerminalRepresentable(view: session.terminal)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
            switch session.phase {
            case .connected: EmptyView()
            case .connecting: ProgressView("Connecting to serial console…").padding().glassEffect()
            case .failed(let msg):
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.largeTitle)
                    Text(running ? msg : "The virtual machine is not running.").multilineTextAlignment(.center)
                    if running { Button("Reconnect") { connect() } }
                }
                .padding(24)
                .glassEffect(in: .rect(cornerRadius: 16))
            }
        }
        .onAppear(perform: connect)
        .onDisappear { session.stop() }
        .onChange(of: connection.domain(uuid)?.state) { old, new in
            if new == .running, old != .running { connect() }
        }
    }

    private func connect() {
        guard running else {
            session.phase = .failed("The virtual machine is not running.")
            return
        }
        session.connect(connection: connection, uuid: uuid, alias: alias)
    }
}
