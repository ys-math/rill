import CoreServices
import Foundation

/// Calls `onChange` whenever a file is written, replaced, created or deleted.
///
/// Watches the file's directory with FSEvents rather than the file itself, which catches
/// in-place rewrites, write-then-rename, and a file that doesn't exist yet. If the directory
/// doesn't exist either, the nearest existing ancestor is watched.
@MainActor
final class FileWatcher {
    let path: String
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?

    init(path: String) {
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.eventsArrived(paths) }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(nil, callback, &context, [watchedDirectory()] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.03,
                                               FSEventStreamCreateFlags(flags))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Must be called before the watcher is released: the stream holds an unretained pointer to it.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func watchedDirectory() -> String {
        var directory = (path as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: directory), directory != "/" {
            directory = (directory as NSString).deletingLastPathComponent
        }
        return directory
    }

    private func eventsArrived(_ paths: [String]) {
        // Events for a not-yet-existing parent directory also matter: creating it may create the file.
        guard paths.contains(where: {
            let changed = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            return changed == path || path.hasPrefix(changed + "/")
        }) else { return }
        onChange?()
    }
}
