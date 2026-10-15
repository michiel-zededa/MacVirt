// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Observation

struct SavedConnection: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var uri: String
    var autoconnect = true
}

struct DomainSummary: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    var uuid: String
    var name: String
    var state: DomainState
    var vcpus: Int
    var memoryMiB: Int
    var cpuPercent: Double
    var persistent: Bool
}

enum DomainAction: String, CaseIterable {
    case start, shutdown, reboot, forceOff, pause, resume

    var title: String {
        switch self {
        case .start: "Run"
        case .shutdown: "Shut Down"
        case .reboot: "Reboot"
        case .forceOff: "Force Off"
        case .pause: "Pause"
        case .resume: "Resume"
        }
    }

    var symbol: String {
        switch self {
        case .start: "play.fill"
        case .shutdown: "power"
        case .reboot: "arrow.clockwise"
        case .forceOff: "bolt.fill"
        case .pause: "pause.fill"
        case .resume: "playpause.fill"
        }
    }

    func isAvailable(for state: DomainState) -> Bool {
        switch self {
        case .start: !state.isActive
        case .shutdown, .reboot, .forceOff: state.isActive
        case .pause: state == .running || state == .blocked
        case .resume: state == .paused
        }
    }
}

@MainActor @Observable
final class ConnectionModel: Identifiable {
    enum Status: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    let id: UUID
    var name: String
    let uri: String
    private(set) var status: Status = .disconnected
    private(set) var domains: [DomainSummary] = []
    private(set) var hostDescription = ""
    var lastError: String?

    var isLocal: Bool { uri == BundledRuntime.localURI }

    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private let queue: DispatchQueue
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCPU: [String: (time: UInt64, at: Date)] = [:]

    init(saved: SavedConnection) {
        id = saved.id
        name = saved.name
        uri = saved.uri
        queue = DispatchQueue(label: "libvirt.\(saved.id)")
    }

    var saved: SavedConnection { SavedConnection(id: id, name: name, uri: uri) }

    // MARK: Connection lifecycle

    func connect() {
        guard status != .connecting, status != .connected else { return }
        status = .connecting
        let uri = self.uri, local = isLocal
        queue.async {
            do {
                if local { try BundledRuntime.ensureDaemon() }
                let conn = try Connection(uri: uri)
                let desc = "\(conn.hostname) · QEMU \(conn.hypervisorVersion)"
                DispatchQueue.main.async {
                    self.connection = conn
                    self.hostDescription = desc
                    self.status = .connected
                    self.startPolling()
                }
            } catch {
                DispatchQueue.main.async { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    func disconnect() {
        timer?.invalidate()
        timer = nil
        let conn = connection
        connection = nil
        domains = []
        status = .disconnected
        queue.async { _ = conn }  // release (virConnectClose) off the main thread
    }

    private func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard let conn = connection else { return }
        let previous = lastCPU
        queue.async {
            guard conn.isAlive else {
                DispatchQueue.main.async {
                    self.disconnect()
                    self.status = .failed("Connection lost")
                }
                return
            }
            let now = Date()
            var summaries: [DomainSummary] = []
            var cpu: [String: (time: UInt64, at: Date)] = [:]
            for d in (try? conn.allDomains()) ?? [] {
                guard let info = try? d.info() else { continue }
                let uuid = d.uuid
                var pct = 0.0
                if let prev = previous[uuid], info.cpuTimeNs >= prev.time, info.state.isActive {
                    let wall = now.timeIntervalSince(prev.at) * 1e9
                    pct = min(100, Double(info.cpuTimeNs - prev.time) / wall / Double(max(info.vcpus, 1)) * 100)
                }
                cpu[uuid] = (info.cpuTimeNs, now)
                summaries.append(DomainSummary(
                    uuid: uuid, name: d.name, state: info.state, vcpus: info.vcpus,
                    memoryMiB: Int(info.maxMemKiB / 1024), cpuPercent: pct, persistent: d.isPersistent))
            }
            summaries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.lastCPU = cpu
                if self.domains != summaries { self.domains = summaries }
            }
        }
    }

    // MARK: Operations (all run on the connection queue)

    /// Runs `work` with the live connection off the main thread.
    func withConnection<T: Sendable>(_ work: @escaping @Sendable (Connection) throws -> T) async throws -> T {
        guard let conn = connection else { throw LibvirtError(message: "Not connected") }
        return try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work(conn) }) }
        }
    }

    func perform(_ action: DomainAction, on uuid: String) {
        Task {
            do {
                try await withConnection { conn in
                    let d = try conn.domain(uuid: uuid)
                    switch action {
                    case .start: try d.start()
                    case .shutdown: try d.shutdown()
                    case .reboot: try d.reboot()
                    case .forceOff: try d.forceOff()
                    case .pause: try d.pause()
                    case .resume: try d.resume()
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
        }
    }

    func domainXML(uuid: String) async throws -> String {
        try await withConnection { try $0.domain(uuid: uuid).xml(inactive: true) }
    }

    func liveDetails(uuid: String) async throws -> DomainDetails {
        try await withConnection { DomainDetails(xml: try $0.domain(uuid: uuid).xml()) }
    }

    func define(xml: String) async throws {
        _ = try await withConnection { try $0.defineDomain(xml: xml).uuid }
        refresh()
    }

    func delete(uuid: String, removeDisks: Bool) async throws {
        let local = isLocal
        try await withConnection { conn in
            let d = try conn.domain(uuid: uuid)
            let details = DomainDetails(xml: try d.xml(inactive: true))
            if try d.info().state.isActive { try d.forceOff() }
            try d.undefine()
            guard removeDisks else { return }
            for disk in details.disks where disk.device == "disk" && !disk.source.isEmpty {
                if local {
                    try? FileManager.default.removeItem(atPath: disk.source)
                } else {
                    try? conn.deleteVolume(path: disk.source)
                }
            }
        }
        refresh()
    }
}
