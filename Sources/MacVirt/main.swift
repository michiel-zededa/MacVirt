// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

let args = CommandLine.arguments
if args.count >= 2, args[1] == "--askpass" {
    Askpass.run(prompt: args.count >= 3 ? args[2] : "Password:")
}

// Writes to a console pipe whose ssh process has exited must fail with EPIPE,
// not kill the app.
signal(SIGPIPE, SIG_IGN)

BundledRuntime.prepare()
Libvirt.initialize()
MacVirtApp.main()
