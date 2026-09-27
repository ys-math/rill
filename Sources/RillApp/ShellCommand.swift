import Foundation
import os

/// Runs a user-configured command line with `/bin/sh`, detached from rill.
enum ShellCommand {
    /// Apps launched from Finder get a minimal PATH; add the usual places nvim lives.
    private static let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin",
                                    "/Library/TeX/texbin"]

    /// Starts `command`; a non-zero exit is logged to `log` as `what` and passed to `onFailure`
    /// on the main thread.
    static func run(_ command: String, what: String, log: Logger,
                    onFailure: (@MainActor @Sendable (Int32) -> Void)? = nil) throws {
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
                let status = process.terminationStatus
                log.error("\(what, privacy: .public) command exited with \(status)")
                if let onFailure { DispatchQueue.main.async { onFailure(status) } }
            }
        }
        try process.run()
    }
}
