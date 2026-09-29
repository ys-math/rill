import AppKit

/// A floating card showing where a link goes: a rendered crop of the target page (the theorem,
/// equation or bibliography entry), or the address of a web link.
@MainActor
final class LinkPreview: NSView {
    private let imageView = NSImageView()
    private let label = Overlay.label("", color: .labelColor)
    private let card = NSView()
    private var constraintsInContainer: [NSLayoutConstraint] = []

    /// Where the preview leads, so Enter can follow it.
    var target: LinkTarget?
    /// Shown by hovering (hidden again when the pointer leaves the link).
    var fromHover = false
    /// The page regions shown, top to bottom (display coordinates), so links inside the card
    /// can be found and previewed in turn. Empty for a web address.
    private(set) var regions: [PagePart] = []
    /// Card points per page point.
    private var scale: CGFloat = 1

    /// The pointer moved over the card (a point in `pagePoint(at:)`'s terms), or left it (nil).
    var onHover: ((CGPoint?) -> Void)?
    /// A click on the card.
    var onClick: ((CGPoint) -> Void)?
    /// The scroll wheel over the card (it belongs to the document underneath).
    var onScroll: ((NSEvent) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        for view in [imageView, label] { card.addSubview(view) }
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: card.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The card takes the pointer: its links can be hovered and clicked.
    override func hitTest(_ point: NSPoint) -> NSView? { isShowing && frame.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isShowing else { return }
        onHover?(localPoint(event))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(localPoint(event))
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    /// An event's location from the card's top-left.
    private func localPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    var isShowing: Bool { !isHidden && superview != nil }

    /// The page point under a point of the card (from its top-left).
    func pagePoint(at local: CGPoint) -> (page: Int, point: CGPoint)? {
        var top: CGFloat = 0
        for region in regions {
            let height = region.rect.height * scale
            if local.y >= top, local.y < top + height {
                return (region.page, CGPoint(x: region.rect.minX + local.x / scale, y: region.rect.minY + (local.y - top) / scale))
            }
            top += height
        }
        return nil
    }

    /// A rect on a page, in `view`'s coordinates, if the card shows it.
    func rect(_ rect: CGRect, onPage page: Int, in view: NSView) -> CGRect? {
        var top: CGFloat = 0
        for region in regions {
            defer { top += region.rect.height * scale }
            guard region.page == page, region.rect.intersects(rect) else { continue }
            let local = CGRect(x: (rect.minX - region.rect.minX) * scale, y: top + (rect.minY - region.rect.minY) * scale,
                               width: rect.width * scale, height: rect.height * scale)
            // The card isn't flipped: from its bottom-left.
            let unflipped = CGRect(x: local.minX, y: bounds.height - local.maxY, width: local.width, height: local.height)
            return convert(unflipped, to: view)
        }
        return nil
    }

    /// Shows `image` (drawn at `size` points) or `text`, next to `anchor` (container coordinates).
    /// `regions` are the page regions the image shows, top to bottom. The card goes under
    /// `beneath` (the hint labels) when given.
    func show(image: CGImage?, size: CGSize, text: String?, regions: [PagePart] = [], near anchor: CGRect,
              in container: NSView, beneath: NSView? = nil) {
        self.regions = regions
        imageView.image = image.map { NSImage(cgImage: $0, size: size) }
        imageView.isHidden = image == nil
        label.stringValue = text ?? ""
        label.isHidden = text == nil
        let bounds = container.bounds
        // Shrunk to fit if needed, keeping the crop's proportions (a long theorem can be tall).
        let fit = image == nil ? 1 : min(1, (bounds.width - 32) / max(size.width, 1), bounds.height * 0.7 / max(size.height, 1))
        let width = min(size.width * fit, bounds.width - 32)
        let height = image == nil ? 34 : size.height * fit

        // Below the link if it fits, otherwise above; kept inside the window.
        let flipped = container.isFlipped
        let below = flipped ? anchor.maxY + 8 : anchor.minY - 8 - height
        let above = flipped ? anchor.minY - 8 - height : anchor.maxY + 8
        let fitsBelow = flipped ? below + height <= bounds.maxY - 8 : below >= bounds.minY + 8
        var origin = CGPoint(x: anchor.minX, y: fitsBelow ? below : above)
        origin.x = min(max(origin.x, 16), bounds.maxX - width - 16)
        origin.y = min(max(origin.y, 8), bounds.maxY - height - 8)

        if superview !== container {
            removeFromSuperview()
            if let beneath, beneath.superview === container {
                container.addSubview(self, positioned: .below, relativeTo: beneath)
            } else {
                container.addSubview(self)
            }
        }
        translatesAutoresizingMaskIntoConstraints = true
        frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        scale = width / max(regions.map(\.rect.width).max() ?? width, 1)
        Overlay.show(self)
    }

    /// Crops from consecutive pages (an environment split by a page break), one below the
    /// other, left-aligned.
    nonisolated static func stack(_ images: [CGImage]) -> CGImage? {
        guard images.count > 1 else { return images.first }
        let width = images.map(\.width).max() ?? 0, height = images.map(\.height).reduce(0, +)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // CoreGraphics draws from the bottom: the first page's part goes at the top.
        var y = height
        for image in images {
            y -= image.height
            context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
        }
        return context.makeImage()
    }

    func hide() {
        target = nil
        fromHover = false
        regions = []
        Overlay.hide(self)
    }
}
