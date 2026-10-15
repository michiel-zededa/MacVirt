// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

let args = CommandLine.arguments
if args.count >= 2, args[1] == "--askpass" {
    Askpass.run(prompt: args.count >= 3 ? args[2] : "Password:")
}

BundledRuntime.prepare()
Libvirt.initialize()
MacVirtApp.main()
