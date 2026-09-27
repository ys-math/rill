import AppKit

/// Native scroll view (trackpad momentum, rubber-banding, pinch). Keys are handled by the
/// window controller, which sits behind the window in the responder chain.
@MainActor
final class DocumentScrollView: NSScrollView {
    /// The user took over with the trackpad or mouse; programmatic motion should stop.
    var onUserScroll: (() -> Void)?
    /// True during a trackpad pinch. Tiles aren't re-rendered until it ends.
    private(set) var isLiveMagnifying = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 10
        drawsBackground = true
        backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.06, alpha: 1) : NSColor(white: 0.90, alpha: 1)
        }
        contentView.postsBoundsChangedNotifications = true
        // Pages run under the transparent title bar; no automatic inset for it.
        automaticallyAdjustsContentInsets = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onUserScroll?()
        if event.phase.contains(.began) { isLiveMagnifying = true }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { isLiveMagnifying = false }
        super.magnify(with: event)
    }
}

/// Centers the document when it's smaller than the viewport instead of pinning it top-left,
/// and keeps scrolling within `allowedRect` when set (single-page mode).
final class CenteringClipView: NSClipView {
    var allowedRect: CGRect?

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        let area = allowedRect ?? document
        if rect.width > area.width || allowedRect == nil && rect.width > document.width {
            rect.origin.x = area.midX - rect.width / 2
        } else if allowedRect != nil {
            rect.origin.x = min(max(rect.origin.x, area.minX), area.maxX - rect.width)
        }
        if rect.height > area.height {
            rect.origin.y = area.midY - rect.height / 2
        } else if allowedRect != nil {
            rect.origin.y = min(max(rect.origin.y, area.minY), area.maxY - rect.height)
        }
        return rect
    }
}
