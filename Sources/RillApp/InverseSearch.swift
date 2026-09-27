import AppKit
import os
import RillCore

let syncLog = Logger(subsystem: "io.github.ys-math.rill", category: "synctex")

@MainActor
enum InverseSearch {
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

        do {
            try ShellCommand.run(command, what: "inverse search", log: syncLog)
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
