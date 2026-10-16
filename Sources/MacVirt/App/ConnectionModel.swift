// SPDX-License-Identifier: GPL-2.0-or-later
import CLibvirt
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

/// One point of a domain's performance history (rates are per second).
struct StatsPoint: Identifiable, Sendable {
    var id: Date { time }
    var time: Date
    var cpuPercent: Double
    var memoryPercent: Double
    var diskReadBps: Double
    var diskWriteBps: Double
    var netRxBps: Double
    var netTxBps: Double
}

enum DomainAction: String, CaseIterable {
    case start, pause, resume, reboot, shutdown, reset, forceOff, save

    var title: String {
        switch self {
        case .start: "Run"
        case .shutdown: "Shut Down"
        case .reboot: "Reboot"
        case .reset: "Force Reset"
        case .forceOff: "Force Off"
        case .pause: "Pause"
        case .resume: "Resume"
        case .save: "Save"
        }
    }

    var symbol: String {
        switch self {
        case .start: "play.fill"
        case .shutdown: "power"
        case .reboot: "arrow.clockwise"
        case .reset: "arrow.counterclockwise.circle"
        case .forceOff: "bolt.fill"
        case .pause: "pause.fill"
        case .resume: "playpause.fill"
        case .save: "square.and.arrow.down"
        }
    }

    /// Actions that need confirmation because the guest may lose data.
    var isDestructive: Bool { self == .forceOff || self == .reset }

    func isAvailable(for state: DomainState) -> Bool {
        switch self {
        case .start: !state.isActive
        case .shutdown, .reboot, .reset, .forceOff: state.isActive
        case .pause: state == .running || state == .blocked
        case .resume: state == .paused
        case .save: state == .running || state == .blocked || state == .paused
        }
    }

    /// The "Shut Down" submenu, as in virt-manager.
    static let shutdownMenu: [DomainAction] = [.reboot, .shutdown, .reset, .forceOff, .save]
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
    var autoconnect: Bool
    private(set) var status: Status = .disconnected
    private(set) var domains: [DomainSummary] = []
    private(set) var history: [String: [StatsPoint]] = [:]
    private(set) var hostname = ""
    private(set) var hypervisor = ""
    private(set) var libvirtVersion = ""
    private(set) var nodeInfo: NodeInfo?
    /// Bumped whenever domains change, so open views can reload their XML.
    private(set) var generation = 0
    var lastError: String?

    var isLocal: Bool { uri == BundledRuntime.localURI }
    var hostDescription: String { "\(hostname) · \(hypervisor)" }

    static let historyLength = 90

    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored let queue: DispatchQueue
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSample: [String: (DomainStatsSample, Date)] = [:]
    @ObservationIgnored private var refreshPending = false

    init(saved: SavedConnection) {
        id = saved.id
        name = saved.name
        uri = saved.uri
        autoconnect = saved.autoconnect
        queue = DispatchQueue(label: "libvirt.\(saved.id)")
    }

    var saved: SavedConnection { SavedConnection(id: id, name: name, uri: uri, autoconnect: autoconnect) }

    var displayHost: String {
        if isLocal { return "This Mac" }
        return URLComponents(string: uri)?.host ?? uri
    }

    // MARK: Connection lifecycle

    func connect() {
        guard status != .connecting, status != .connected else { return }
        status = .connecting
        let uri = self.uri, local = isLocal
        queue.async {
            do {
                if local { try BundledRuntime.ensureDaemon() }
                let conn = try Connection(uri: uri)
                if local { BundledRuntime.ensureDefaultPool(conn) }
                let host = conn.hostname
                let hv = "\(conn.hypervisorType) \(conn.hypervisorVersion)"
                let lv = conn.libvirtVersion
                let node = try? conn.nodeInfo()
                conn.onDomainLifecycle { [weak self] in
                    DispatchQueue.main.async { self?.scheduleRefresh() }
                }
                DispatchQueue.main.async {
                    self.connection = conn
                    self.hostname = host
                    self.hypervisor = hv
                    self.libvirtVersion = lv
                    self.nodeInfo = node
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
        history = [:]
        lastSample = [:]
        status = .disconnected
        queue.async { _ = conn }  // release (virConnectClose) off the main thread
    }

    private func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Preferences.shared.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Coalesces bursts of lifecycle events into one refresh.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.refreshPending = false
            self.refresh()
            self.generation += 1
        }
    }

    func refresh() {
        guard let conn = connection else { return }
        let previous = lastSample
        queue.async {
            guard conn.isAlive else {
                DispatchQueue.main.async {
                    self.disconnect()
                    self.status = .failed("Connection lost")
                }
                return
            }
            let samples: [DomainStatsSample]
            do {
                samples = try conn.allDomainStats()
            } catch {
                return
            }
            let transient = Set(((try? conn.allDomains(flags: UInt32(VIR_CONNECT_LIST_DOMAINS_TRANSIENT.rawValue))) ?? []).map(\.uuid))
            let now = Date()
            var summaries: [DomainSummary] = []
            var points: [String: StatsPoint] = [:]
            var latest: [String: (DomainStatsSample, Date)] = [:]
            for s in samples {
                var cpu = 0.0
                var point = StatsPoint(time: now, cpuPercent: 0, memoryPercent: 0, diskReadBps: 0, diskWriteBps: 0, netRxBps: 0, netTxBps: 0)
                if let (prev, at) = previous[s.uuid], s.state.isActive {
                    let dt = max(now.timeIntervalSince(at), 0.001)
                    func rate(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / dt : 0 }
                    cpu = min(100, rate(s.cpuTimeNs, prev.cpuTimeNs) / 1e9 / Double(max(s.vcpus, 1)) * 100)
                    point.cpuPercent = cpu
                    point.diskReadBps = rate(s.diskReadBytes, prev.diskReadBytes)
                    point.diskWriteBps = rate(s.diskWriteBytes, prev.diskWriteBytes)
                    point.netRxBps = rate(s.netRxBytes, prev.netRxBytes)
                    point.netTxBps = rate(s.netTxBytes, prev.netTxBytes)
                }
                if s.state.isActive, s.maxMemoryKiB > 0 {
                    let used = s.memoryUsedKiB ?? s.memoryKiB
                    point.memoryPercent = min(100, Double(used) / Double(s.maxMemoryKiB) * 100)
                }
                latest[s.uuid] = (s, now)
                if s.state.isActive { points[s.uuid] = point }
                summaries.append(DomainSummary(
                    uuid: s.uuid, name: s.name, state: s.state, vcpus: s.vcpus,
                    memoryMiB: Int(s.maxMemoryKiB / 1024), cpuPercent: cpu, persistent: !transient.contains(s.uuid)))
            }
            summaries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.lastSample = latest
                var h = self.history.filter { latest[$0.key] != nil }
                for (uuid, p) in points {
                    var series = h[uuid] ?? []
                    series.append(p)
                    if series.count > Self.historyLength { series.removeFirst(series.count - Self.historyLength) }
                    h[uuid] = series
                }
                self.history = h
                if self.domains != summaries {
                    let stateChanged = self.domains.map(\.state) != summaries.map(\.state)
                        || self.domains.map(\.uuid) != summaries.map(\.uuid)
                    self.domains = summaries
                    if stateChanged { self.generation += 1 }
                }
            }
        }
    }

    func domain(_ uuid: String) -> DomainSummary? { domains.first { $0.uuid == uuid } }

    // MARK: Operations (all run on the connection queue)

    /// Runs `work` with the live connection off the main thread.
    func withConnection<T: Sendable>(_ work: @escaping @Sendable (Connection) throws -> T) async throws -> T {
        guard let conn = connection else { throw LibvirtError(message: "Not connected") }
        return try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work(conn) }) }
        }
    }

    /// Runs `work` on a domain and refreshes afterwards; errors go to `lastError`.
    func run(_ uuid: String, _ work: @escaping @Sendable (Domain) throws -> Void) {
        Task {
            do {
                try await withConnection { try work(try $0.domain(uuid: uuid)) }
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
            generation += 1
        }
    }

    func perform(_ action: DomainAction, on uuid: String) {
        run(uuid) { d in
            switch action {
            case .start: try d.start()
            case .shutdown: try d.shutdown()
            case .reboot: try d.reboot()
            case .reset: try d.reset()
            case .forceOff: try d.forceOff()
            case .pause: try d.pause()
            case .resume: try d.resume()
            case .save: try d.managedSave()
            }
        }
    }

    func domainXML(uuid: String, inactive: Bool = true) async throws -> String {
        try await withConnection { try $0.domain(uuid: uuid).xml(inactive: inactive) }
    }

    func liveDetails(uuid: String) async throws -> DomainDetails {
        try await withConnection { DomainDetails(xml: try $0.domain(uuid: uuid).xml()) }
    }

    func define(xml: String) async throws {
        _ = try await withConnection { try $0.defineDomain(xml: xml).uuid }
        refresh()
        generation += 1
    }

    /// Undefines the domain and deletes the given storage paths.
    func delete(uuid: String, storagePaths: [String]) async throws {
        let local = isLocal
        let failures: [String] = try await withConnection { conn in
            let d = try conn.domain(uuid: uuid)
            if d.isActive { try d.forceOff() }
            try d.undefine()
            var failed: [String] = []
            for path in storagePaths {
                if let vol = try? conn.volume(path: path) {
                    do { try vol.delete() } catch { failed.append("\(path): \(error.localizedDescription)") }
                } else if local {
                    do { try FileManager.default.removeItem(atPath: path) } catch { failed.append("\(path): \(error.localizedDescription)") }
                } else {
                    failed.append("\(path): not in a storage pool")
                }
            }
            return failed
        }
        refresh()
        generation += 1
        if !failures.isEmpty {
            throw LibvirtError(message: "The VM was deleted, but some storage could not be removed:\n" + failures.joined(separator: "\n"))
        }
    }
}
