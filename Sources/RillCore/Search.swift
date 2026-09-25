import CoreGraphics
import Foundation

/// A search query with Vim's smart-case: case-insensitive unless it contains an uppercase letter.
public struct SearchQuery: Equatable, Sendable {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var isCaseSensitive: Bool {
        text.contains { $0.isUppercase }
    }

    /// Non-overlapping matches in `haystack`, as UTF-16 ranges (what PDFKit selections use).
    public func ranges(in haystack: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let hay = haystack as NSString
        let options: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: hay.length)
        while searchRange.length > 0 {
            let found = hay.range(of: text, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            result.append(found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: hay.length - next)
        }
        return result
    }
}

/// One search hit: a page and a rect in page points (origin top-left).
public struct SearchMatch: Equatable, Sendable {
    public var page: Int
    public var rect: CGRect

    public init(page: Int, rect: CGRect) {
        self.page = page
        self.rect = rect
    }
}

public enum SearchNavigation {
    /// Reading order: page, then top to bottom, then left to right (lines within ~half a line match).
    public static func sorted(_ matches: [SearchMatch]) -> [SearchMatch] {
        matches.sorted { a, b in
            if a.page != b.page { return a.page < b.page }
            if abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) / 2 { return a.rect.midY < b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
    }

    /// The match to show first when searching from (`page`, `y`): the first at or below that
    /// point going forward, or the last above it going backward, wrapping around the document.
    /// `matches` must be in reading order.
    public static func firstIndex(in matches: [SearchMatch], fromPage page: Int, y: CGFloat, forward: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        func isAfter(_ m: SearchMatch) -> Bool { m.page > page || (m.page == page && m.rect.minY >= y) }
        if forward {
            return matches.firstIndex(where: isAfter) ?? 0
        }
        return matches.lastIndex(where: { !isAfter($0) }) ?? matches.count - 1
    }

    /// `n` / `N`: step `count` matches from `index`, wrapping.
    public static func step(from index: Int, by count: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return ((index + count) % total + total) % total
    }
}
