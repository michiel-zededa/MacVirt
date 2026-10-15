// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Observation

enum SidebarItem: Hashable {
    case connection(UUID)
    case domain(UUID, String)

    var connectionID: UUID {
        switch self {
        case .connection(let id), .domain(let id, _): id
        }
    }
}

/// Identifies a console window. Codable so SwiftUI can restore it.
struct ConsoleTarget: Codable, Hashable {
    var connectionID: UUID
    var domainUUID: String
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var connections: [ConnectionModel] = []
    var selection: SidebarItem?

    private static let defaultsKey = "connections"

    private init() {
        var saved: [SavedConnection] = []
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            saved = decoded
        } else {
            saved = [SavedConnection(name: "Local (QEMU)", uri: BundledRuntime.localURI)]
        }
        connections = saved.map(ConnectionModel.init(saved:))
        for (c, s) in zip(connections, saved) where s.autoconnect { c.connect() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections.map(\.saved)) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func connection(_ id: UUID) -> ConnectionModel? { connections.first { $0.id == id } }

    func add(name: String, uri: String) {
        let model = ConnectionModel(saved: SavedConnection(name: name, uri: uri))
        connections.append(model)
        persist()
        selection = .connection(model.id)
        model.connect()
    }

    func remove(_ id: UUID) {
        connection(id)?.disconnect()
        connections.removeAll { $0.id == id }
        if selection?.connectionID == id { selection = nil }
        persist()
    }

    var selectedConnection: ConnectionModel? { selection.flatMap { connection($0.connectionID) } }

    var selectedDomain: (ConnectionModel, DomainSummary)? {
        guard case .domain(let cid, let uuid) = selection, let c = connection(cid),
              let d = c.domains.first(where: { $0.uuid == uuid }) else { return nil }
        return (c, d)
    }
}
