import Darwin
import Foundation
import os

private let launchLog = Logger(subsystem: "io.github.ys-math.rill", category: "launch")

/// Logs how long after the process started the first page appeared, once as a thumbnail and
/// once sharp: the spec's "cold launch → first page visible < 300 ms" target.
@MainActor
enum LaunchTiming {
    private static var loggedThumbnail = false
    private static var loggedSharp = false

    static func firstPixels(sharp: Bool) {
        if sharp ? loggedSharp : loggedThumbnail { return }
        if sharp { loggedSharp = true } else { loggedThumbnail = true }
        guard let started = processStart() else { return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        launchLog.notice("first page \(sharp ? "sharp" : "thumbnail", privacy: .public) \(ms) ms after process start")
    }

    private static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }
}
