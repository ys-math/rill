import AppKit
import UniformTypeIdentifiers
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

    /// A changed config parsed and is now in effect.
    var onApplied: (() -> Void)?

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
            if changed {
                NotificationCenter.default.post(name: .rillConfigDidChange, object: self)
                onApplied?()
            }
        } catch {
            configLog.error("config error: \(error.description, privacy: .public)")
            problem = "config.toml \(error.description) (keeping previous settings)"
        }
    }

    /// Opens the file with `edit_command`, or else in the app that handles it (the default text
    /// editor if none does), creating it from a commented template first if it doesn't exist.
    /// Saving it applies the changes through the watcher. Returns a message if that failed.
    func edit() -> String? {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Config.template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return "could not create \(url.path): \(error.localizedDescription)"
            }
        }
        if let command = config.renderedEditCommand(path: url.path) {
            configLog.debug("edit: \(command, privacy: .public)")
            do {
                try ShellCommand.run(command, what: "edit", log: configLog) { [weak self] status in
                    self?.onProblem?("edit_command exited with status \(status)")
                }
            } catch {
                return "edit_command: \(error.localizedDescription)"
            }
            return nil
        }
        let workspace = NSWorkspace.shared
        guard let editor = workspace.urlForApplication(toOpen: url) ?? workspace.urlForApplication(toOpen: .plainText) else {
            return "no app to open \(url.lastPathComponent) with"
        }
        let path = url.path
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { configLog.error("could not open \(path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        return nil
    }
}
