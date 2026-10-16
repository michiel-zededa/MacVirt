// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Observation

/// User preferences (Settings window), persisted in UserDefaults.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    private let d = UserDefaults.standard

    var pollInterval: Double { didSet { d.set(pollInterval, forKey: "pollInterval") } }
    var confirmForceOff: Bool { didSet { d.set(confirmForceOff, forKey: "confirmForceOff") } }
    var confirmPowerOff: Bool { didSet { d.set(confirmPowerOff, forKey: "confirmPowerOff") } }
    var confirmPause: Bool { didSet { d.set(confirmPause, forKey: "confirmPause") } }
    var confirmRemoveDevice: Bool { didSet { d.set(confirmRemoveDevice, forKey: "confirmRemoveDevice") } }
    var confirmUnapplied: Bool { didSet { d.set(confirmUnapplied, forKey: "confirmUnapplied") } }
    var confirmDeleteStorage: Bool { didSet { d.set(confirmDeleteStorage, forKey: "confirmDeleteStorage") } }
    /// 0 = never, 1 = only in fullscreen, 2 = always
    var consoleScaling: Int { didSet { d.set(consoleScaling, forKey: "consoleScaling") } }
    var consoleAutoconnect: Bool { didSet { d.set(consoleAutoconnect, forKey: "consoleAutoconnect") } }
    var xmlEditingEnabled: Bool { didSet { d.set(xmlEditingEnabled, forKey: "xmlEditingEnabled") } }
    var showCPUColumn: Bool { didSet { d.set(showCPUColumn, forKey: "showCPUColumn") } }
    var showMemoryColumn: Bool { didSet { d.set(showMemoryColumn, forKey: "showMemoryColumn") } }
    var defaultStorageFormat: String { didSet { d.set(defaultStorageFormat, forKey: "defaultStorageFormat") } }
    var newVMFirmware: String { didSet { d.set(newVMFirmware, forKey: "newVMFirmware") } }

    private init() {
        d.register(defaults: [
            "pollInterval": 2.0, "confirmForceOff": true, "confirmPowerOff": false, "confirmPause": false,
            "confirmRemoveDevice": true, "confirmUnapplied": true, "confirmDeleteStorage": true,
            "consoleScaling": 2, "consoleAutoconnect": true, "xmlEditingEnabled": true,
            "showCPUColumn": true, "showMemoryColumn": false, "defaultStorageFormat": "qcow2", "newVMFirmware": "default",
        ])
        pollInterval = d.double(forKey: "pollInterval")
        confirmForceOff = d.bool(forKey: "confirmForceOff")
        confirmPowerOff = d.bool(forKey: "confirmPowerOff")
        confirmPause = d.bool(forKey: "confirmPause")
        confirmRemoveDevice = d.bool(forKey: "confirmRemoveDevice")
        confirmUnapplied = d.bool(forKey: "confirmUnapplied")
        confirmDeleteStorage = d.bool(forKey: "confirmDeleteStorage")
        consoleScaling = d.integer(forKey: "consoleScaling")
        consoleAutoconnect = d.bool(forKey: "consoleAutoconnect")
        xmlEditingEnabled = d.bool(forKey: "xmlEditingEnabled")
        showCPUColumn = d.bool(forKey: "showCPUColumn")
        showMemoryColumn = d.bool(forKey: "showMemoryColumn")
        defaultStorageFormat = d.string(forKey: "defaultStorageFormat") ?? "qcow2"
        newVMFirmware = d.string(forKey: "newVMFirmware") ?? "default"
    }
}
