// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-2.0-or-later
import PackageDescription

let package = Package(
    name: "MacVirt",
    platforms: [.macOS("26.0")],
    targets: [
        .systemLibrary(
            name: "CLibvirt",
            path: "Sources/CLibvirt",
            pkgConfig: "libvirt",
            providers: [.brew(["libvirt"])]
        ),
        .executableTarget(
            name: "MacVirt",
            dependencies: ["CLibvirt"],
            path: "Sources/MacVirt",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("z")]
        ),
    ]
)
