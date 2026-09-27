import Foundation

/// A character on a page: `index` is the UTF-16 offset into that page's text, as PDFKit uses.
public struct TextPosition: Comparable, Hashable, Sendable {
    public var page: Int
    public var index: Int

    public init(page: Int, index: Int) {
        self.page = page
        self.index = index
    }

    public static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.page != b.page ? a.page < b.page : a.index < b.index
    }
}

/// The text structure of one page, for visual-mode motions.
public struct PageText: Sendable {
    public var length: Int
    /// Text lines, in reading order.
    public var lines: [NSRange]
    /// Words, in order (from the system's word segmentation, which handles Japanese).
    public var words: [NSRange]

    public init(length: Int, lines: [NSRange], words: [NSRange]) {
        self.length = length
        self.lines = lines
        self.words = words
    }

    /// The line containing `index`, or the nearest one before it.
    public func lineIndex(containing index: Int) -> Int? {
        guard !lines.isEmpty else { return nil }
        return lines.lastIndex { $0.location <= index } ?? 0
    }
}

/// Character, word and line motions for visual mode. (Up and down use the page geometry and
/// live in the app.)
public enum VisualMotion: Sendable {
    case left, right, wordForward, wordBackward, wordEnd, lineStart, lineEnd

    /// Moves `count` times. `text` supplies each page's structure; motions continue across
    /// pages where Vim's would continue across lines.
    public func apply(to start: TextPosition, count: Int = 1, pageCount: Int,
                      text: (Int) -> PageText?) -> TextPosition {
        var position = start
        for _ in 0..<max(count, 1) {
            guard let next = step(from: position, pageCount: pageCount, text: text) else { break }
            position = next
        }
        return position
    }

    private func step(from p: TextPosition, pageCount: Int, text: (Int) -> PageText?) -> TextPosition? {
        guard let page = text(p.page) else { return nil }
        switch self {
        case .left:
            if p.index > 0 { return TextPosition(page: p.page, index: p.index - 1) }
            return previousPage(of: p.page, text: text).map { TextPosition(page: $0.index, index: max($0.text.length - 1, 0)) }
        case .right:
            if p.index + 1 < page.length { return TextPosition(page: p.page, index: p.index + 1) }
            return nextPage(of: p.page, pageCount: pageCount, text: text).map { TextPosition(page: $0.index, index: 0) }
        case .wordForward:
            if let word = page.words.first(where: { $0.location > p.index }) { return TextPosition(page: p.page, index: word.location) }
            return nextPage(of: p.page, pageCount: pageCount, text: text).map {
                TextPosition(page: $0.index, index: $0.text.words.first?.location ?? 0)
            }
        case .wordBackward:
            if let word = page.words.last(where: { $0.location < p.index }) { return TextPosition(page: p.page, index: word.location) }
            return previousPage(of: p.page, text: text).map {
                TextPosition(page: $0.index, index: $0.text.words.last?.location ?? 0)
            }
        case .wordEnd:
            if let word = page.words.first(where: { NSMaxRange($0) - 1 > p.index }) {
                return TextPosition(page: p.page, index: NSMaxRange(word) - 1)
            }
            return nextPage(of: p.page, pageCount: pageCount, text: text).map { next in
                TextPosition(page: next.index, index: next.text.words.first.map { NSMaxRange($0) - 1 } ?? 0)
            }
        case .lineStart:
            guard let line = page.lineIndex(containing: p.index) else { return nil }
            return TextPosition(page: p.page, index: page.lines[line].location)
        case .lineEnd:
            guard let line = page.lineIndex(containing: p.index) else { return nil }
            return TextPosition(page: p.page, index: max(NSMaxRange(page.lines[line]) - 1, page.lines[line].location))
        }
    }

    private func nextPage(of page: Int, pageCount: Int, text: (Int) -> PageText?) -> (index: Int, text: PageText)? {
        var i = page + 1
        while i < pageCount {
            if let t = text(i), t.length > 0 { return (i, t) }
            i += 1
        }
        return nil
    }

    private func previousPage(of page: Int, text: (Int) -> PageText?) -> (index: Int, text: PageText)? {
        var i = page - 1
        while i >= 0 {
            if let t = text(i), t.length > 0 { return (i, t) }
            i -= 1
        }
        return nil
    }
}
