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

    private var pages: [PageLayer] = []
    private var tiles: [TileKey: CALayer] = [:]
    private lazy var scheduler = RenderScheduler(source: source) { [weak self] request, image in
        self?.install(request, image)
    }
    private var currentLevel = 0

    init(source: PDFSource, layout: PageLayout) {
        self.source = source
        self.layout = layout
        super.init(frame: CGRect(origin: .zero, size: layout.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for frame in layout.pageFrames {
            let page = PageLayer(frame: frame)
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
    func updateContent(visible: CGRect, magnification: CGFloat, settled: Bool) {
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
            currentLevel = TileGrid.level(forPixelsPerPoint: magnification * (window?.backingScaleFactor ?? 2))
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

    init(frame: CGRect) {
        super.init()
        self.frame = frame
        backgroundColor = .white
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
