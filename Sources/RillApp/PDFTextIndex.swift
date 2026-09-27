import Foundation
import PDFKit
import RillCore

/// A line of text on screen, for `F` (inverse search) and `yf` (yank).
struct TextLine: Sendable {
    var page: Int
    /// Display coordinates within the page (points, origin top-left).
    var rect: CGRect
    var text: String
    /// Characters of the page's text this line covers (where visual mode starts).
    var range: NSRange
}

/// A link annotation on screen, for `f`.
struct LinkTarget: Sendable {
    enum Destination: Sendable {
        /// `point` is in display coordinates within `page`, when the link names one.
        case page(Int, point: CGPoint?)
        case url(URL)
    }

    var page: Int
    var rect: CGRect
    var destination: Destination
}

/// A bookmark from the PDF's outline, for `t`.
struct OutlineEntry: Sendable {
    var title: String
    var depth: Int
    var page: Int
    /// Display coordinates within `page`, when the bookmark names a spot.
    var point: CGPoint?
}

/// Text, lines and links of one PDF version, read with PDFKit off the main thread.
/// Built from the same bytes as the `PDFSource` on screen, so results always match what's shown.
actor PDFTextIndex {
    private let document: PDFDocument
    private var texts: [Int: String] = [:]
    private var geometries: [Int: PageGeometry] = [:]

    init?(data: Data) {
        guard let document = PDFDocument(data: data) else { return nil }
        self.document = document
    }

    // MARK: - Search

    /// Reads every page's text ahead of the first search (started when `/` is pressed).
    func warmUp() {
        for index in 0..<document.pageCount where texts[index] == nil {
            if Task.isCancelled { return }
            if let page = document.page(at: index) { _ = text(of: index, page) }
        }
    }

    /// Every match of `query`, in reading order. The first search reads all page text (cached).
    func search(_ query: SearchQuery) -> [SearchMatch] {
        guard !query.text.isEmpty else { return [] }
        var matches: [SearchMatch] = []
        for index in 0..<document.pageCount {
            if Task.isCancelled { return [] }
            guard let page = document.page(at: index) else { continue }
            let text = text(of: index, page)
            let ranges = query.ranges(in: text)
            guard !ranges.isEmpty else { continue }
            let geometry = geometry(of: index, page)
            for range in ranges {
                guard let selection = page.selection(for: range) else { continue }
                // A match can wrap across lines; highlight each line's part.
                for line in selection.selectionsByLine() {
                    let rect = geometry.displayRect(line.bounds(for: page))
                    if rect.width > 0, rect.height > 0 { matches.append(SearchMatch(page: index, rect: rect)) }
                }
            }
        }
        return SearchNavigation.sorted(matches)
    }

    // MARK: - Hint targets

    /// Text lines intersecting `regions` (display coordinates per page).
    func lines(in regions: [Int: CGRect]) -> [TextLine] {
        var result: [TextLine] = []
        for (index, region) in regions.sorted(by: { $0.key < $1.key }) {
            guard let page = document.page(at: index),
                  let all = page.selection(for: page.bounds(for: .cropBox))
            else { continue }
            let geometry = geometry(of: index, page)
            for line in all.selectionsByLine() {
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rect = geometry.displayRect(line.bounds(for: page))
                guard !text.isEmpty, rect.height > 1, rect.intersects(region) else { continue }
                let range = line.numberOfTextRanges(on: page) > 0 ? line.range(at: 0, on: page) : NSRange(location: 0, length: 0)
                result.append(TextLine(page: index, rect: rect, text: text, range: range))
            }
        }
        return result
    }

    /// Link annotations intersecting `regions`.
    func links(in regions: [Int: CGRect]) -> [LinkTarget] {
        var result: [LinkTarget] = []
        for (index, region) in regions.sorted(by: { $0.key < $1.key }) {
            guard let page = document.page(at: index) else { continue }
            let geometry = geometry(of: index, page)
            // `type` is the subtype without its leading slash.
            for annotation in page.annotations where annotation.type == "Link" {
                let rect = geometry.displayRect(annotation.bounds)
                guard rect.intersects(region), let destination = destination(of: annotation) else { continue }
                result.append(LinkTarget(page: index, rect: rect, destination: destination))
            }
        }
        return result
    }

    // MARK: - Visual mode

    private var pageTexts: [Int: PageText] = [:]
    private var lineRects: [Int: [CGRect]] = [:]

    var pageCount: Int { document.pageCount }

    /// A page's lines and words, for motions.
    func pageText(_ index: Int) -> PageText? {
        if let cached = pageTexts[index] { return cached }
        guard let page = document.page(at: index) else { return nil }
        let string = text(of: index, page) as NSString
        var lines: [NSRange] = [], rects: [CGRect] = []
        let geometry = geometry(of: index, page)
        for line in page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [] where line.numberOfTextRanges(on: page) > 0 {
            let range = line.range(at: 0, on: page)
            guard range.length > 0 else { continue }
            lines.append(range)
            rects.append(geometry.displayRect(line.bounds(for: page)))
        }
        var words: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            words.append(range)
        }
        let text = PageText(length: string.length, lines: lines, words: words)
        pageTexts[index] = text
        lineRects[index] = rects
        return text
    }

    /// Display rect of each line from `pageText` (same order).
    func lineRects(_ index: Int) -> [CGRect] {
        _ = pageText(index)
        return lineRects[index] ?? []
    }

    /// The character nearest `point` (display coordinates) on `page`, if any.
    func characterIndex(page index: Int, at point: CGPoint) -> Int? {
        guard let page = document.page(at: index) else { return nil }
        let i = page.characterIndex(at: geometry(of: index, page).pagePoint(point))
        return i >= 0 ? i : nil
    }

    /// Display rect of one character (the visual-mode cursor).
    func characterRect(_ position: TextPosition) -> CGRect? {
        guard let page = document.page(at: position.page) else { return nil }
        let rect = page.characterBounds(at: position.index)
        guard rect.width > 0 || rect.height > 0 else { return nil }
        return geometry(of: position.page, page).displayRect(rect)
    }

    /// The text between two positions (inclusive) and its line rects per page.
    func selection(from a: TextPosition, to b: TextPosition) -> (text: String, rects: [Int: [CGRect]]) {
        let (start, end) = a <= b ? (a, b) : (b, a)
        guard let startPage = document.page(at: start.page), let endPage = document.page(at: end.page),
              let selection = document.selection(from: startPage, atCharacterIndex: start.index,
                                                 to: endPage, atCharacterIndex: end.index)
        else { return ("", [:]) }
        var rects: [Int: [CGRect]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                let rect = geometry(of: index, page).displayRect(line.bounds(for: page))
                if rect.width > 0, rect.height > 0 { rects[index, default: []].append(rect) }
            }
        }
        return (selection.string ?? "", rects)
    }

    // MARK: - Links by page (hover)

    private var pageLinks: [Int: [LinkTarget]] = [:]

    /// Every link on a page, cached; for hover previews.
    func links(onPage index: Int) -> [LinkTarget] {
        if let cached = pageLinks[index] { return cached }
        guard let page = document.page(at: index) else { return [] }
        let links = self.links(in: [index: CGRect(origin: .zero, size: geometry(of: index, page).displaySize)])
        pageLinks[index] = links
        return links
    }

    // MARK: - Outline

    /// The document's bookmarks in reading order, flattened with their nesting depth.
    func outline() -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [OutlineEntry] = []
        func visit(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let target = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if !title.isEmpty, let target, let page = target.page {
                    let index = document.index(for: page)
                    let raw = target.point
                    let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
                    let point = raw.y == unspecified ? nil
                        : geometry(of: index, page).displayPoint(CGPoint(x: raw.x == unspecified ? 0 : raw.x, y: raw.y))
                    entries.append(OutlineEntry(title: title, depth: depth, page: index, point: point))
                }
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return entries
    }

    // MARK: - Private

    private func destination(of annotation: PDFAnnotation) -> LinkTarget.Destination? {
        if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
            return .url(url)
        }
        let target = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
        guard let target, let page = target.page else { return nil }
        let index = document.index(for: page)
        let raw = target.point
        let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
        guard raw.x != unspecified || raw.y != unspecified else { return .page(index, point: nil) }
        let geometry = geometry(of: index, page)
        // A missing coordinate means "don't change it"; use the page's edge.
        let point = CGPoint(x: raw.x == unspecified ? geometry.cropBox.minX : raw.x,
                            y: raw.y == unspecified ? geometry.cropBox.maxY : raw.y)
        return .page(index, point: geometry.displayPoint(point))
    }

    private func text(of index: Int, _ page: PDFPage) -> String {
        if let cached = texts[index] { return cached }
        let text = page.string ?? ""
        texts[index] = text
        return text
    }

    private func geometry(of index: Int, _ page: PDFPage) -> PageGeometry {
        if let cached = geometries[index] { return cached }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        geometries[index] = geometry
        return geometry
    }
}
