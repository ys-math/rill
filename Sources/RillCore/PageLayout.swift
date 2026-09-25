import CoreGraphics

/// Continuous vertical layout of pages in document points (unmagnified), top-down (flipped).
public struct PageLayout: Equatable, Sendable {
    public let pageFrames: [CGRect]
    public let size: CGSize
    public let gap: CGFloat

    /// - Parameter pageSizes: displayed page sizes in points (after /Rotate).
    public init(pageSizes: [CGSize], gap: CGFloat = 8, margin: CGFloat = 16) {
        let width = (pageSizes.map(\.width).max() ?? 0) + 2 * margin
        var y = margin
        var frames: [CGRect] = []
        frames.reserveCapacity(pageSizes.count)
        for size in pageSizes {
            frames.append(CGRect(x: ((width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height))
            y += size.height + gap
        }
        self.pageFrames = frames
        self.gap = gap
        self.size = CGSize(width: width, height: frames.isEmpty ? 0 : y - gap + margin)
    }

    public var pageCount: Int { pageFrames.count }

    /// Index of the page containing `y`, or the nearest one (gaps belong to the page above).
    public func pageIndex(atY y: CGFloat) -> Int {
        guard !pageFrames.isEmpty else { return 0 }
        var lo = 0, hi = pageFrames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pageFrames[mid].minY <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Indices of pages intersecting a vertical span.
    public func pages(inYRange minY: CGFloat, _ maxY: CGFloat) -> ClosedRange<Int>? {
        guard !pageFrames.isEmpty, maxY >= pageFrames[0].minY, minY <= pageFrames[pageFrames.count - 1].maxY else {
            return nil
        }
        return pageIndex(atY: minY)...pageIndex(atY: maxY)
    }

    /// Scroll offset that puts page `index` at the top of the viewport, with half a gap above it.
    public func topOffset(ofPage index: Int) -> CGFloat {
        let i = min(max(index, 0), pageFrames.count - 1)
        return max(pageFrames[i].minY - gap / 2, 0)
    }

    /// Magnification at which the widest page (plus a small inset) fills the viewport width.
    public func fitWidthMagnification(viewportWidth: CGFloat, inset: CGFloat = 16) -> CGFloat {
        let widest = pageFrames.map(\.width).max() ?? 1
        return viewportWidth / (widest + 2 * inset)
    }

    /// Magnification at which page `index` fits entirely in the viewport.
    public func fitPageMagnification(page index: Int, viewport: CGSize, inset: CGFloat = 16) -> CGFloat {
        guard !pageFrames.isEmpty else { return 1 }
        let page = pageFrames[min(max(index, 0), pageFrames.count - 1)]
        return min(viewport.width / (page.width + 2 * inset), viewport.height / (page.height + 2 * gap))
    }
}
