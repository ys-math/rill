import AppKit
import os
import RillCore

private let configLog = Logger(subsystem: "io.github.ys-math.rill", category: "config")

extension Notification.Name {
    /// Posted on the main thread after the config file changed and parsed.
    static let rillConfigDidChange = Notification.Name("rillConfigDidChange")
}

/// The live config: loaded at launch, reloaded whenever the file changes. A file that fails
/// to parse is reported and the last good config stays in effect.
@MainActor
final class ConfigStore {
    static let shared = ConfigStore(
        url: ProcessInfo.processInfo.environment["RILL_CONFIG"].map { URL(fileURLWithPath: $0) } ?? Config.defaultURL())

    let url: URL
    private(set) var config = Config()
    /// Something is wrong with the file (shown to the user as a toast). A problem found before
    /// this is set, e.g. at launch, is delivered as soon as it is.
    var onProblem: ((String) -> Void)? {
        didSet { if let problem { onProblem?(problem) } }
    }
    /// The current file's problem, if any.
    private(set) var problem: String? {
        didSet { if let problem, problem != oldValue { onProblem?(problem) } }
    }

    private let watcher: FileWatcher
    private var lastText: String?

    init(url: URL) {
        self.url = url
        self.watcher = FileWatcher(path: url.path)
        watcher.onChange = { [weak self] in self?.load() }
        load()
        watcher.start()
    }

    func load() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard text != lastText else { return }
        lastText = text
        do {
            let (config, warnings) = try Config.parse(text)
            let changed = config != self.config
            self.config = config
            configLog.debug("loaded \(self.url.path, privacy: .public) with \(warnings.count) warnings")
            problem = warnings.isEmpty ? nil : "config: " + warnings.joined(separator: "\n")
            if changed { NotificationCenter.default.post(name: .rillConfigDidChange, object: self) }
        } catch {
            configLog.error("config error: \(error.description, privacy: .public)")
            problem = "config.toml \(error.description) (keeping previous settings)"
        }
    }
}
