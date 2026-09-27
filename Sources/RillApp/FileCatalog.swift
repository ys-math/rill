import AppKit
import QuickLookThumbnailing
import RillCore

/// Where the file picker's entries come from: recently opened PDFs, then PDFs Spotlight knows
/// about under the configured roots.
@MainActor
enum FileCatalog {
    /// Recently opened PDFs that still exist, most recent first.
    static func recents(from store: DocumentStateStore) -> [String] {
        store.recentPaths().filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// PDFs under `roots` (with `~` expanded), via Spotlight. Hidden folders are skipped.
    static func pdfs(under roots: [String]) async -> [String] {
        let paths = await withTaskGroup(of: [String].self) { group in
            for root in roots.map({ expandHome($0) }) where FileManager.default.fileExists(atPath: root) {
                group.addTask { await mdfind(root) }
            }
            var all: [String] = []
            for await found in group { all += found }
            return all
        }
        var seen = Set<String>()
        return paths.filter { path in
            !path.split(separator: "/").contains { $0.hasPrefix(".") } && seen.insert(path).inserted
        }.sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    nonisolated private static func mdfind(_ root: String) async -> [String] {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", root, "kMDItemContentType == 'com.adobe.pdf'"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                continuation.resume(returning: lines)
            }
            do { try process.run() } catch { continuation.resume(returning: []) }
        }
    }

    /// A small first-page thumbnail (QuickLook, cached by the system).
    static func thumbnail(for path: String, size: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size,
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
