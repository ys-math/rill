import AppKit
import QuartzCore
import RillCore

/// The scrollable document: one layer per page, drawn in unmagnified points.
///
/// Each page shows a low-resolution thumbnail as soon as it's near the viewport, then sharp
/// tiles at the current zoom level fade in on top. Tiles from an older zoom level stay until
/// the new level fully covers the page, so the page is never blank.
@MainActor
final class DocumentView: NSView {
    nonisolated static let thumbnailScale: CGFloat = 0.6
    /// Keep thumbnails for this many pages either side of the viewport.
    private static let thumbnailRetention = 12
    private static let tileFadeDuration: CFTimeInterval = 0.1

    let source: PDFSource
    let layout: PageLayout
    /// Pages are recoloured as dark paper.
    let dark: Bool

    private var pages: [PageLayer] = []
    private var tiles: [TileKey: CALayer] = [:]
    private lazy var scheduler = RenderScheduler(source: source, dark: dark) { [weak self] request, image in
        self?.install(request, image)
    }
    private var currentLevel = 0
    /// Tiles still missing before `prepare`'s completion fires.
    private var readiness: (missing: Set<TileKey>, completion: () -> Void)?

    init(source: PDFSource, layout: PageLayout, dark: Bool) {
        self.source = source
        self.layout = layout
        self.dark = dark
        super.init(frame: CGRect(origin: .zero, size: layout.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for frame in layout.pageFrames {
            let page = PageLayer(frame: frame, paper: dark ? PaperRecolor.paperColor : .white)
            layer!.addSublayer(page)
            pages.append(page)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Brings rendering in line with what's on screen. Called on every scroll and zoom frame,
    /// so it only does bookkeeping; rendering happens on the scheduler's threads.
    /// - Parameter settled: false while zoom is changing; tiles are then left alone until it settles.
    func updateContent(visible: CGRect, magnification: CGFloat, backingScale: CGFloat, settled: Bool) {
        guard let visiblePages = layout.pages(inYRange: visible.minY, visible.maxY) else { return }
        let prefetch = visible.insetBy(dx: 0, dy: -visible.height)
        let prefetchPages = layout.pages(inYRange: prefetch.minY, prefetch.maxY) ?? visiblePages
        var wanted: [RenderRequest: RenderScheduler.Priority] = [:]

        // Thumbnails: visible pages first, then neighbours.
        for index in max(prefetchPages.lowerBound - 2, 0)...min(prefetchPages.upperBound + 2, pages.count - 1)
        where !pages[index].hasThumbnail {
            wanted[.thumbnail(page: index)] = visiblePages.contains(index) ? .visible : .prefetch
        }
        let keep = (visiblePages.lowerBound - Self.thumbnailRetention)...(visiblePages.upperBound + Self.thumbnailRetention)
        for (index, page) in pages.enumerated() where page.hasThumbnail && !keep.contains(index) {
            page.dropThumbnail()
        }

        if settled {
            currentLevel = TileGrid.level(forPixelsPerPoint: magnification * backingScale)
            for index in prefetchPages {
                let frame = layout.pageFrames[index]
                let region = (visiblePages.contains(index) ? visible : prefetch).offsetBy(dx: -frame.minX, dy: -frame.minY)
                let priority: RenderScheduler.Priority = visiblePages.contains(index) ? .visible : .prefetch
                for key in TileGrid.keys(page: index, level: currentLevel, pageSize: frame.size, visible: region)
                where tiles[key] == nil {
                    wanted[.tile(key)] = priority
                }
            }
            evictTiles(keeping: prefetch)
        }
        // Mid-zoom, keep whatever tiles are already queued rather than cancelling them every frame.
        scheduler.update(wanted: wanted, retainingTiles: !settled)
    }

    /// Renders thumbnails for `range` synchronously if missing, so a jump never lands on blank pages.
    func ensureThumbnails(_ range: ClosedRange<Int>) {
        for index in max(range.lowerBound, 0)...min(range.upperBound, pages.count - 1) where !pages[index].hasThumbnail {
            if let image = scheduler.renderNow(.thumbnail(page: index)) { pages[index].setThumbnail(image) }
        }
    }

    /// Renders what `visible` needs while this view is still offscreen, then calls `completion`
    /// once every visible tile is in, so it can be swapped in without a soft or blank frame.
    func prepare(visible: CGRect, magnification: CGFloat, backingScale: CGFloat, completion: @escaping () -> Void) {
        if let pages = layout.pages(inYRange: visible.minY, visible.maxY) { ensureThumbnails(pages) }
        updateContent(visible: visible, magnification: magnification, backingScale: backingScale, settled: true)
        var missing = Set<TileKey>()
        for index in layout.pages(inYRange: visible.minY, visible.maxY) ?? 0...(-1) {
            let frame = layout.pageFrames[index]
            let region = visible.offsetBy(dx: -frame.minX, dy: -frame.minY)
            missing.formUnion(TileGrid.keys(page: index, level: currentLevel, pageSize: frame.size, visible: region)
                .filter { tiles[$0] == nil })
        }
        if missing.isEmpty { completion() } else { readiness = (missing, completion) }
    }

    /// ⌘-click: a point in document coordinates.
    var onCommandClick: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onCommandClick?(convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Briefly highlights `rect` (document coordinates): the forward-search target.
    func flash(_ rect: CGRect) {
        let highlight = CALayer()
        highlight.frame = rect.insetBy(dx: -3, dy: -2)
        highlight.cornerRadius = 3
        highlight.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.4).cgColor
        highlight.zPosition = 10
        highlight.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(highlight)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.25
        fade.duration = 0.8
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { highlight.removeFromSuperlayer() }
        highlight.opacity = 0
        highlight.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Search highlights: every match, and the current one more strongly.
    func setHighlights(_ matches: [SearchMatch], current: Int?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for page in pages { page.setHighlights(nil, current: nil) }
        var byPage: [Int: [CGRect]] = [:]
        for match in matches where match.page < pages.count { byPage[match.page, default: []].append(match.rect) }
        let currentMatch = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        for (index, rects) in byPage {
            pages[index].setHighlights(rects, current: currentMatch?.page == index ? currentMatch?.rect : nil)
        }
    }

    /// Stops all rendering. Call before discarding the view.
    func teardown() {
        readiness = nil
        scheduler.cancelAll()
    }

    // MARK: - Private

    private func install(_ request: RenderRequest, _ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch request {
        case .thumbnail(let index):
            pages[index].setThumbnail(image)
        case .tile(let key):
            guard tiles[key] == nil else { return }
            let scale = TileGrid.scale(forLevel: key.level)
            let rect = TileGrid.rect(of: key, pageSize: layout.pageFrames[key.page].size)
            let tile = CALayer()
            tile.contents = image
            tile.contentsGravity = .resize
            // The bitmap is rounded up to whole pixels; size the layer to match so it isn't squashed.
            tile.frame = CGRect(x: rect.minX, y: rect.minY,
                                width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            tile.zPosition = key.level == currentLevel ? 1 : 0
            pages[key.page].content.addSublayer(tile)
            tiles[key] = tile
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = Self.tileFadeDuration
                tile.add(fade, forKey: "fade")
            }
            retireOldLevels(onPage: key.page)
            if var ready = readiness {
                ready.missing.remove(key)
                if ready.missing.isEmpty {
                    readiness = nil
                    ready.completion()
                } else {
                    readiness = ready
                }
            }
        }
    }

    /// Once the current level covers everything visible on a page, older levels are dead weight.
    private func retireOldLevels(onPage index: Int) {
        guard let visible = superview.map({ convert($0.bounds, from: $0) }) else { return }
        let frame = layout.pageFrames[index]
        let region = visible.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let needed = TileGrid.keys(page: index, level: currentLevel, pageSize: frame.size, visible: region)
        guard needed.allSatisfy({ tiles[$0] != nil }) else { return }
        for (key, tile) in tiles where key.page == index && key.level != currentLevel {
            tile.removeFromSuperlayer()
            tiles[key] = nil
        }
    }

    private func evictTiles(keeping region: CGRect) {
        for (key, tile) in tiles {
            let frame = layout.pageFrames[key.page]
            let rect = TileGrid.rect(of: key, pageSize: frame.size).offsetBy(dx: frame.minX, dy: frame.minY)
            // Tiles of an old level stay while they're still covering for the current one.
            let stale = key.level != currentLevel && tilesCover(page: key.page, rect: rect)
            if !rect.intersects(region) || stale {
                tile.removeFromSuperlayer()
                tiles[key] = nil
            } else {
                tile.zPosition = key.level == currentLevel ? 1 : 0
            }
        }
    }

    private func tilesCover(page: Int, rect: CGRect) -> Bool {
        let frame = layout.pageFrames[page]
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        return TileGrid.keys(page: page, level: currentLevel, pageSize: frame.size, visible: local)
            .allSatisfy { tiles[$0] != nil }
    }
}

/// A page: a shadowed white card with a clipped content layer holding the thumbnail and tiles.
@MainActor
private final class PageLayer: CALayer {
    let content = CALayer()
    private(set) var hasThumbnail = false

    init(frame: CGRect, paper: CGColor) {
        super.init()
        self.frame = frame
        backgroundColor = paper
        shadowColor = .black
        shadowOpacity = 0.18
        shadowRadius = 3
        shadowOffset = CGSize(width: 0, height: 1)
        shadowPath = CGPath(rect: bounds, transform: nil)
        actions = Self.noActions

        content.frame = bounds
        content.masksToBounds = true
        content.contentsGravity = .resize
        content.actions = Self.noActions
        addSublayer(content)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var highlights: CAShapeLayer?
    private var currentHighlight: CAShapeLayer?

    func setHighlights(_ rects: [CGRect]?, current: CGRect?) {
        highlights?.removeFromSuperlayer()
        currentHighlight?.removeFromSuperlayer()
        highlights = nil
        currentHighlight = nil
        guard let rects, !rects.isEmpty else { return }
        highlights = addHighlight(rects, color: NSColor.systemYellow.withAlphaComponent(0.35))
        if let current {
            currentHighlight = addHighlight([current], color: NSColor.systemOrange.withAlphaComponent(0.55))
        }
    }

    private func addHighlight(_ rects: [CGRect], color: NSColor) -> CAShapeLayer {
        let path = CGMutablePath()
        for rect in rects { path.addRoundedRect(in: rect.insetBy(dx: -1, dy: -1), cornerWidth: 2, cornerHeight: 2) }
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = path
        layer.fillColor = color.cgColor
        layer.zPosition = 5
        layer.actions = Self.noActions
        addSublayer(layer)
        return layer
    }

    func setThumbnail(_ image: CGImage) {
        content.contents = image
        hasThumbnail = true
    }

    func dropThumbnail() {
        content.contents = nil
        hasThumbnail = false
    }

    static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(),
    ]
}
