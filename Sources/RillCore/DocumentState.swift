import CoreGraphics
import Foundation

/// A scroll position that survives layout changes: which page is at the top of the
/// viewport, and how far down that page (as a fraction of its height) the viewport starts.
public struct PagePosition: Codable, Equatable, Sendable {
    public var page: Int
    /// (viewport top − page top) / page height. Slightly > 1 in the gap below a page,
    /// negative above the first page.
    public var offset: Double

    public init(page: Int, offset: Double) {
        self.page = page
        self.offset = offset
    }
}

extension PageLayout {
    public func position(atY y: CGFloat) -> PagePosition {
        guard !pageFrames.isEmpty else { return PagePosition(page: 0, offset: 0) }
        let index = pageIndex(atY: y)
        let frame = pageFrames[index]
        return PagePosition(page: index, offset: Double((y - frame.minY) / frame.height))
    }

    /// The viewport-top y for a position. Pages beyond the end clamp to the last page's top.
    public func y(for position: PagePosition) -> CGFloat {
        guard !pageFrames.isEmpty else { return 0 }
        if position.page >= pageFrames.count { return pageFrames[pageFrames.count - 1].minY - gap / 2 }
        let frame = pageFrames[max(position.page, 0)]
        return frame.minY + CGFloat(position.offset) * frame.height
    }
}

public enum ZoomSetting: Codable, Equatable, Sendable {
    case fitWidth
    case fitPage
    case magnification(Double)
}

/// What rill remembers about a document between launches.
public struct DocumentState: Codable, Equatable, Sendable {
    public var position: PagePosition
    /// Horizontal scroll origin in document points (only matters when zoomed past the width).
    public var x: Double
    public var zoom: ZoomSetting
    public var lastOpened: Date
    /// `m{a-z}` marks.
    public var marks: [String: PagePosition]

    public init(position: PagePosition, x: Double = 0, zoom: ZoomSetting, lastOpened: Date = Date(),
                marks: [String: PagePosition] = [:]) {
        self.position = position
        self.x = x
        self.zoom = zoom
        self.lastOpened = lastOpened
        self.marks = marks
    }

    private enum CodingKeys: String, CodingKey { case position, x, zoom, lastOpened, marks }

    // Written by hand so state saved before a field existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(PagePosition.self, forKey: .position)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        zoom = try c.decodeIfPresent(ZoomSetting.self, forKey: .zoom) ?? .fitWidth
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? .distantPast
        marks = try c.decodeIfPresent([String: PagePosition].self, forKey: .marks) ?? [:]
    }
}

/// Per-document state keyed by absolute path, persisted as JSON. Keeps the most recently
/// opened `capacity` documents; this is also rill's recent-files list.
public final class DocumentStateStore {
    public let fileURL: URL
    public let capacity: Int
    private var states: [String: DocumentState]

    public init(fileURL: URL, capacity: Int = 500) {
        self.fileURL = fileURL
        self.capacity = capacity
        let data = try? Data(contentsOf: fileURL)
        self.states = data.flatMap { try? Self.decoder.decode([String: DocumentState].self, from: $0) } ?? [:]
    }

    /// `~/Library/Application Support/rill/documents.json`
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rill/documents.json")
    }

    public func state(forPath path: String) -> DocumentState? {
        states[path]
    }

    public func set(_ state: DocumentState, forPath path: String) {
        states[path] = state
        if states.count > capacity {
            let oldest = states.sorted { $0.value.lastOpened < $1.value.lastOpened }.prefix(states.count - capacity)
            for (key, _) in oldest { states[key] = nil }
        }
    }

    /// Paths, most recently opened first.
    public func recentPaths(limit: Int = .max) -> [String] {
        states.sorted { $0.value.lastOpened > $1.value.lastOpened }.prefix(limit).map(\.key)
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(states).write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
