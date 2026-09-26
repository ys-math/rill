import AppKit
import os
import RillCore

let syncLog = Logger(subsystem: "io.github.ys-math.rill", category: "synctex")

@MainActor
enum InverseSearch {
    /// Apps launched from Finder get a minimal PATH; add the usual places nvim lives.
    private static let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin",
                                    "/Library/TeX/texbin"]

    /// Runs the inverse-search command for `location`, then activates the editor's terminal.
    static func open(_ location: SourceLocation, config: Config = ConfigStore.shared.config) {
        let command: String
        do {
            command = try config.inverseCommand.render(location)
        } catch {
            syncLog.error("inverse search: refusing unsafe path \(location.file, privacy: .public)")
            NSSound.beep()
            return
        }
        syncLog.debug("inverse search: \(command, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (extraPath + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                syncLog.error("inverse search command exited with \(process.terminationStatus)")
            }
        }
        do {
            try process.run()
        } catch {
            syncLog.error("inverse search: could not run command: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return
        }

        if let bundleID = config.activateOnInverse,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        }
    }
}
