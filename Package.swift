// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "rill",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "RillApp", targets: ["RillApp"]),
        .executable(name: "rill", targets: ["rill"]),
    ],
    targets: [
        // Shared, UI-free logic: CLI parsing, IPC messages, config. Everything testable lives here.
        .target(name: "RillCore"),
        // The AppKit application, bundled into Rill.app by the Makefile.
        .executableTarget(name: "RillApp", dependencies: ["RillCore"]),
        // The command-line client used by vimtex and the shell.
        .executableTarget(name: "rill", dependencies: ["RillCore"]),
        .testTarget(name: "RillCoreTests", dependencies: ["RillCore"]),
    ]
)
