// SPDX-License-Identifier: GPL-2.0-or-later
// SSH_ASKPASS implementation: ssh runs Resources/askpass.sh, which re-executes
// MacVirt with `--askpass <prompt>`. The answer goes to stdout.

import AppKit

enum Askpass {
    static func run(prompt: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate()

        let alert = NSAlert()
        alert.messageText = "SSH"
        alert.informativeText = prompt

        // Host key confirmation ("Are you sure you want to continue connecting (yes/no/[fingerprint])?")
        if prompt.contains("(yes/no") {
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                print("yes")
                exit(0)
            }
            exit(1)
        }

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            print(field.stringValue)
            exit(0)
        }
        exit(1)
    }
}
