import Foundation
import PDFKit
import RillCore

/// A line of text on screen, for `F` (inverse search) and `yf` (yank).
struct TextLine: Sendable {
    var page: Int
    /// Display coordinates within the page (points, origin top-left).
    var rect: CGRect
    var text: String
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
                result.append(TextLine(page: index, rect: rect, text: text))
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
