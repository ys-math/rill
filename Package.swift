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
        // The official SyncTeX parser, vendored. See Sources/CSynctex/VENDORED.md.
        .target(
            name: "CSynctex",
            cSettings: [.unsafeFlags(["-w"])], // third-party code; don't surface its warnings
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Shared, UI-free logic: CLI parsing, IPC, SyncTeX, config. Everything testable lives here.
        .target(name: "RillCore", dependencies: ["CSynctex"]),
        // The AppKit application, bundled into Rill.app by the Makefile.
        .executableTarget(name: "RillApp", dependencies: ["RillCore"]),
        // The command-line client used by vimtex and the shell.
        .executableTarget(name: "rill", dependencies: ["RillCore"]),
        .testTarget(name: "RillCoreTests", dependencies: ["RillCore"], resources: [.copy("Fixtures")]),
    ]
)
