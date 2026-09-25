import AppKit

/// Native scroll view (trackpad momentum, rubber-banding, pinch) that also takes keys.
@MainActor
final class DocumentScrollView: NSScrollView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onKeyUp: ((NSEvent) -> Void)?
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
                ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.90, alpha: 1)
        }
        contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        onKeyUp?(event)
    }

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

/// Centers the document when it's smaller than the viewport instead of pinning it top-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = document.midX - rect.width / 2 }
        if rect.height > document.height { rect.origin.y = document.midY - rect.height / 2 }
        return rect
    }
}
