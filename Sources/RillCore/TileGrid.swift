import CoreGraphics
import Foundation

/// Identifies one rendered tile: a square of `TileGrid.tilePixels` pixels of page `page`
/// rendered at `level` (see `TileGrid.scale(forLevel:)`).
public struct TileKey: Hashable, Sendable {
    public var page: Int
    public var level: Int
    public var column: Int
    public var row: Int

    public init(page: Int, level: Int, column: Int, row: Int) {
        self.page = page
        self.level = level
        self.column = column
        self.row = row
    }
}

/// Tile math. Render resolution is quantized to quarter-octave levels so small zoom
/// changes reuse tiles, always rounding up so tiles are never softer than the screen.
public enum TileGrid {
    public static let tilePixels = 512
    public static let maxLevel = 16 // 2^(16/4) = 16 px per point

    /// Pixels per point for a level.
    public static func scale(forLevel level: Int) -> CGFloat {
        pow(2, CGFloat(level) / 4)
    }

    /// The smallest level at least as sharp as `pixelsPerPoint`.
    public static func level(forPixelsPerPoint pixelsPerPoint: CGFloat) -> Int {
        let level = Int((log2(max(pixelsPerPoint, 0.01)) * 4 - 1e-9).rounded(.up))
        return min(max(level, -8), maxLevel)
    }

    /// Tile rect in page points (flipped, origin at the page's top-left). Edge tiles are clipped to the page.
    public static func rect(of key: TileKey, pageSize: CGSize) -> CGRect {
        let side = CGFloat(tilePixels) / scale(forLevel: key.level)
        let tile = CGRect(x: CGFloat(key.column) * side, y: CGFloat(key.row) * side, width: side, height: side)
        return tile.intersection(CGRect(origin: .zero, size: pageSize))
    }

    /// Tiles of `page` at `level` that intersect `visible` (in page points).
    public static func keys(page: Int, level: Int, pageSize: CGSize, visible: CGRect) -> [TileKey] {
        let region = visible.intersection(CGRect(origin: .zero, size: pageSize))
        guard !region.isNull, region.width > 0, region.height > 0 else { return [] }
        let side = CGFloat(tilePixels) / scale(forLevel: level)
        let c0 = Int((region.minX / side).rounded(.down)), c1 = Int((region.maxX / side).rounded(.up)) - 1
        let r0 = Int((region.minY / side).rounded(.down)), r1 = Int((region.maxY / side).rounded(.up)) - 1
        var keys: [TileKey] = []
        for r in r0...max(r0, r1) {
            for c in c0...max(c0, c1) { keys.append(TileKey(page: page, level: level, column: c, row: r)) }
        }
        return keys
    }
}
