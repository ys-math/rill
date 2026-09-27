import CoreGraphics

/// Continuous vertical layout of pages in document points (unmagnified), top-down (flipped).
///
/// Pages sit in rows: one page per row, or two facing pages side by side in a spread. Each page may show
/// only part of itself (its trim, after auto-trimming the margins); `pageFrames` are the
/// visible cards, and `origin(ofPage:)` is where the page's own (0, 0) lands, so page display
/// coordinates convert with `origin`, not with the frame.
public struct PageLayout: Equatable, Sendable {
    public enum Spread: String, CaseIterable, Sendable {
        /// One page per row.
        case off
        /// Two pages per row: 1–2, 3–4, …
        case pairs
        /// Like a printed book: page 1 alone on the right, then 2–3, 4–5, …
        case book
    }

    public let pageFrames: [CGRect]
    /// The part of each page shown, in page display coordinates. The whole page when untrimmed.
    public let trims: [CGRect]
    /// Page indices in each row, top to bottom.
    public let rows: [ClosedRange<Int>]
    /// The union of each row's page frames. Pages in a row share their top edge.
    public let rowFrames: [CGRect]
    public let size: CGSize
    public let gap: CGFloat
    public let margin: CGFloat
    public let spread: Spread

    /// - Parameters:
    ///   - pageSizes: displayed page sizes in points (after /Rotate).
    ///   - trims: the part of each page to show (page display coordinates); nil shows whole pages.
    public init(pageSizes: [CGSize], trims: [CGRect]? = nil, spread: Spread = .off, gap: CGFloat = 8, margin: CGFloat = 16) {
        let trims = pageSizes.indices.map { i in
            trims.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? CGRect(origin: .zero, size: pageSizes[i])
        }
        // Which pages share a row, and which side each one sits on.
        var rows: [ClosedRange<Int>] = []
        var isLeft = [Bool](repeating: true, count: pageSizes.count)
        switch spread {
        case .off:
            rows = pageSizes.indices.map { $0...$0 }
        case .pairs, .book:
            let shift = spread == .book ? 1 : 0
            for i in pageSizes.indices { isLeft[i] = (i + shift) % 2 == 0 }
            var start = 0
            while start < pageSizes.count {
                let end = isLeft[start] && start + 1 < pageSizes.count ? start + 1 : start
                rows.append(start...end)
                start = end + 1
            }
        }

        var frames = [CGRect](repeating: .zero, count: pageSizes.count)
        var rowFrames: [CGRect] = []
        var width: CGFloat
        var y = margin
        if spread == .off {
            width = (trims.map(\.width).max() ?? 0) + 2 * margin
            for (i, trim) in trims.enumerated() {
                frames[i] = CGRect(x: ((width - trim.width) / 2).rounded(), y: y, width: trim.width, height: trim.height)
                rowFrames.append(frames[i])
                y += trim.height + gap
            }
        } else {
            // Left pages end at the spine and right pages start there, so facing pages touch
            // like an open book whatever their widths.
            let leftWidth = trims.indices.filter { isLeft[$0] }.map { trims[$0].width }.max() ?? 0
            let rightWidth = trims.indices.filter { !isLeft[$0] }.map { trims[$0].width }.max() ?? 0
            width = margin + leftWidth + rightWidth + margin
            let spine = (margin + leftWidth).rounded()
            for row in rows {
                var rowFrame = CGRect.null
                for i in row {
                    let trim = trims[i]
                    let x = isLeft[i] ? spine - trim.width : spine
                    frames[i] = CGRect(x: x, y: y, width: trim.width, height: trim.height)
                    rowFrame = rowFrame.union(frames[i])
                }
                rowFrames.append(rowFrame)
                y += rowFrame.height + gap
            }
        }
        self.pageFrames = frames
        self.trims = trims
        self.rows = rows
        self.rowFrames = rowFrames
        self.gap = gap
        self.margin = margin
        self.spread = spread
        self.size = CGSize(width: width, height: rows.isEmpty ? 0 : y - gap + margin)
    }

    public var pageCount: Int { pageFrames.count }
    public var rowCount: Int { rows.count }

    /// The edge where page `index` meets its facing page in a spread, or nil when it has none.
    public func spineEdge(ofPage index: Int) -> CGRectEdge? {
        let row = rows[rowIndex(ofPage: index)]
        guard row.count == 2 else { return nil }
        return index == row.lowerBound ? .maxXEdge : .minXEdge
    }

    /// Where page `index`'s display coordinates put their origin, in document points.
    public func origin(ofPage index: Int) -> CGPoint {
        CGPoint(x: pageFrames[index].minX - trims[index].minX, y: pageFrames[index].minY - trims[index].minY)
    }

    /// Converts a document point to page `index`'s display coordinates.
    public func pagePoint(_ point: CGPoint, onPage index: Int) -> CGPoint {
        let origin = origin(ofPage: index)
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// Index of the row containing `y`, or the nearest one (gaps belong to the row above).
    public func rowIndex(atY y: CGFloat) -> Int {
        guard !rowFrames.isEmpty else { return 0 }
        var lo = 0, hi = rowFrames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowFrames[mid].minY <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func rowIndex(ofPage index: Int) -> Int {
        guard !rows.isEmpty else { return 0 }
        let page = min(max(index, 0), pageCount - 1)
        var lo = 0, hi = rows.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rows[mid].lowerBound <= page { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The first page of the row containing `y`, or of the nearest one.
    public func pageIndex(atY y: CGFloat) -> Int {
        rows.isEmpty ? 0 : rows[rowIndex(atY: y)].lowerBound
    }

    /// The page under `point`, or the nearest one in its row.
    public func pageIndex(at point: CGPoint) -> Int {
        guard !rows.isEmpty else { return 0 }
        return rows[rowIndex(atY: point.y)].min { a, b in
            distance(pageFrames[a], point.x) < distance(pageFrames[b], point.x)
        }!
    }

    private func distance(_ frame: CGRect, _ x: CGFloat) -> CGFloat {
        x < frame.minX ? frame.minX - x : x > frame.maxX ? x - frame.maxX : 0
    }

    /// Indices of pages in rows intersecting a vertical span.
    public func pages(inYRange minY: CGFloat, _ maxY: CGFloat) -> ClosedRange<Int>? {
        guard let first = rowFrames.first, let last = rowFrames.last, maxY >= first.minY, minY <= last.maxY else {
            return nil
        }
        return rows[rowIndex(atY: minY)].lowerBound...rows[rowIndex(atY: maxY)].upperBound
    }

    /// Scroll offset that puts page `index` (its row) at the top of the viewport, with half a gap above it.
    public func topOffset(ofPage index: Int) -> CGFloat {
        topOffset(ofRow: rowIndex(ofPage: index))
    }

    public func topOffset(ofRow index: Int) -> CGFloat {
        let i = min(max(index, 0), rowFrames.count - 1)
        return max(rowFrames[i].minY - gap / 2, 0)
    }

    /// Magnification at which the widest row (plus a small inset) fills the viewport width.
    public func fitWidthMagnification(viewportWidth: CGFloat, inset: CGFloat = 16) -> CGFloat {
        let widest = max(size.width - 2 * margin, 1)
        return viewportWidth / (widest + 2 * inset)
    }

    /// Magnification at which page `index` (its whole row, in a spread) fits entirely in the viewport.
    public func fitPageMagnification(page index: Int, viewport: CGSize, inset: CGFloat = 16) -> CGFloat {
        guard !rowFrames.isEmpty else { return 1 }
        let row = rowFrames[rowIndex(ofPage: index)]
        return min(viewport.width / (row.width + 2 * inset), viewport.height / (row.height + 2 * gap))
    }
}
