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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShowing: Bool { !isHidden && superview != nil }

    /// Shows `image` (drawn at `size` points) or `text`, next to `anchor` (container coordinates).
    func show(image: CGImage?, size: CGSize, text: String?, near anchor: CGRect, in container: NSView) {
        imageView.image = image.map { NSImage(cgImage: $0, size: size) }
        imageView.isHidden = image == nil
        label.stringValue = text ?? ""
        label.isHidden = text == nil
        let bounds = container.bounds
        let width = min(size.width, bounds.width - 32)
        let height = image == nil ? 34 : min(size.height * width / max(size.width, 1), bounds.height * 0.45)

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
            container.addSubview(self)
        }
        translatesAutoresizingMaskIntoConstraints = true
        frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        Overlay.show(self)
    }

    func hide() {
        target = nil
        fromHover = false
        Overlay.hide(self)
    }
}
