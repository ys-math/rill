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
    /// A plain click (following a link under it).
    var onClick: ((CGPoint) -> Void)?
    /// The pointer moved over the document (link previews), or left it (nil).
    var onHover: ((CGPoint?) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            onCommandClick?(point)
        } else if event.clickCount == 1 {
            onClick?(point)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
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

    /// Single-page mode: hide every page but `page` (nil shows them all).
    func showOnly(page: Int?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in pages.enumerated() { layer.isHidden = page.map { $0 != index } ?? false }
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

    /// Visual-mode selection (per page) and cursor.
    func setSelection(_ rects: [Int: [CGRect]], cursor: (page: Int, rect: CGRect)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (index, page) in pages.enumerated() {
            page.setOverlay("selection", rects[index], color: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55), z: 6)
            let caret = cursor.flatMap { $0.page == index ? CGRect(x: $0.rect.minX - 1, y: $0.rect.minY, width: 2, height: $0.rect.height) : nil }
            page.setOverlay("cursor", caret.map { [$0] }, color: NSColor.controlAccentColor, z: 7, rounded: false)
        }
    }

    /// After a recompile: a brief accent bar in the left margin beside each changed band
    /// (page display coordinates). An empty band (a deletion) gets a short tick.
    func showChangeMarkers(_ bands: [Int: [ClosedRange<CGFloat>]]) {
        guard let root = layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, ranges) in bands where index < layout.pageFrames.count {
            let frame = layout.pageFrames[index]
            for range in ranges {
                let height = max(range.upperBound - range.lowerBound, 5)
                let marker = CALayer()
                marker.frame = CGRect(x: frame.minX - 8, y: frame.minY + (range.lowerBound + range.upperBound) / 2 - height / 2,
                                      width: 3, height: height)
                marker.cornerRadius = 1.5
                marker.name = "change"
                marker.backgroundColor = NSColor.controlAccentColor.cgColor
                marker.zPosition = 10
                marker.opacity = 0
                root.addSublayer(marker)

                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 1, 0]
                fade.keyTimes = reduceMotion ? [0, 0, 1, 1] : [0, 0.1, 0.65, 1]
                fade.duration = 1.4
                CATransaction.begin()
                CATransaction.setCompletionBlock { marker.removeFromSuperlayer() }
                marker.add(fade, forKey: "fade")
                CATransaction.commit()
            }
        }
    }

    var debugChangeMarkers: [String] {
        (layer?.sublayers ?? []).filter { $0.name == "change" }.map { "y\(Int($0.frame.minY))+\(Int($0.frame.height))" }
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

        LaunchTiming.firstPixels(sharp: { if case .tile = request { true } else { false } }())
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

    /// Shape layers drawn over the page: search highlights, the visual selection, its cursor.
    private var overlays: [String: CAShapeLayer] = [:]

    func setHighlights(_ rects: [CGRect]?, current: CGRect?) {
        setOverlay("search", rects, color: NSColor.systemYellow.withAlphaComponent(0.35), z: 5)
        setOverlay("current", current.map { [$0] }, color: NSColor.systemOrange.withAlphaComponent(0.55), z: 5.5)
    }

    func setOverlay(_ key: String, _ rects: [CGRect]?, color: NSColor, z: CGFloat, rounded: Bool = true) {
        overlays[key]?.removeFromSuperlayer()
        overlays[key] = nil
        guard let rects, !rects.isEmpty else { return }
        let path = CGMutablePath()
        for rect in rects {
            if rounded { path.addRoundedRect(in: rect.insetBy(dx: -1, dy: -1), cornerWidth: 2, cornerHeight: 2) } else { path.addRect(rect) }
        }
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = path
        layer.fillColor = color.cgColor
        layer.zPosition = z
        layer.actions = Self.noActions
        addSublayer(layer)
        overlays[key] = layer
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
