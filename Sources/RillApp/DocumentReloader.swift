import CoreServices
import Foundation
import os
import RillCore

let reloadLog = Logger(subsystem: "io.github.ys-math.rill", category: "reload")

/// Watches a PDF on disk and produces a fresh `PDFSource` each time a complete new version lands.
///
/// FSEvents on the parent directory catches both in-place rewrites (pdflatex, lualatex) and
/// write-then-rename. A version is accepted only once it ends in `%%EOF` and parses; until
/// then the old one stays on screen and attempts back off for up to ~2 s.
@MainActor
final class DocumentReloader {
    /// Delays before each attempt after a change (cumulative ~2 s).
    private static let attemptDelays: [Duration] = [.zero, .milliseconds(50), .milliseconds(100), .milliseconds(200),
                                                    .milliseconds(400), .milliseconds(600), .milliseconds(650)]

    let url: URL
    /// Delivers the new version and when its change was first noticed (for latency logging).
    var onReload: ((PDFSource, ContinuousClock.Instant) -> Void)?

    private let watchedPath: String
    private var stream: FSEventStreamRef?
    private var currentData: Data
    private var attempts: Task<Void, Never>?

    init(url: URL, current: PDFSource) {
        self.url = url
        self.watchedPath = url.resolvingSymlinksInPath().path
        self.currentData = current.data
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let reloader = Unmanaged<DocumentReloader>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { reloader.eventsArrived(paths) }
        }
        let directory = (watchedPath as NSString).deletingLastPathComponent
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(nil, callback, &context, [directory] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.03,
                                               FSEventStreamCreateFlags(flags))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        attempts?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// `r`: reload even if the bytes haven't changed.
    func forceReload() {
        scheduleAttempts(force: true)
    }

    private func eventsArrived(_ paths: [String]) {
        guard paths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == watchedPath }) else { return }
        scheduleAttempts(force: false)
    }

    /// A newer change supersedes any attempts still running for an older one.
    private func scheduleAttempts(force: Bool) {
        attempts?.cancel()
        let url = url
        let current = force ? nil : currentData
        let noticed = ContinuousClock.now
        attempts = Task { [weak self] in
            for (attempt, delay) in Self.attemptDelays.enumerated() {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                let outcome = await Task.detached(priority: .userInitiated) { Self.load(url, unlessEqualTo: current) }.value
                if Task.isCancelled { return }
                switch outcome {
                case .unchanged:
                    return
                case .incomplete:
                    reloadLog.debug("attempt \(attempt) found an incomplete file")
                    continue
                case .loaded(let source):
                    reloadLog.debug("loaded \(source.pageCount) pages on attempt \(attempt), \((ContinuousClock.now - noticed).formatted(.units(allowed: [.milliseconds])), privacy: .public) after the change")
                    self?.currentData = source.data
                    self?.onReload?(source, noticed)
                    return
                }
            }
            reloadLog.notice("gave up: file still incomplete after retries")
        }
    }

    private enum Outcome: Sendable {
        case unchanged
        case incomplete
        case loaded(PDFSource)
    }

    nonisolated private static func load(_ url: URL, unlessEqualTo current: Data?) -> Outcome {
        guard let data = try? Data(contentsOf: url) else { return .incomplete }
        if data == current { return .unchanged }
        guard PDFCompleteness.looksComplete(data), let source = try? PDFSource(data: data, url: url) else {
            return .incomplete
        }
        return .loaded(source)
    }
}
