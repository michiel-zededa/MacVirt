// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-2.0-or-later
import PackageDescription

let package = Package(
    name: "MacVirt",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Terminal emulator for serial consoles (MIT). Pinned: later releases
        // need the Metal compiler, which only ships with full Xcode.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
    ],
    targets: [
        .systemLibrary(
            name: "CLibvirt",
            path: "Sources/CLibvirt",
            pkgConfig: "libvirt",
            providers: [.brew(["libvirt"])]
        ),
        .executableTarget(
            name: "MacVirt",
            dependencies: ["CLibvirt", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/MacVirt",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("z")]
        ),
    ]
)
