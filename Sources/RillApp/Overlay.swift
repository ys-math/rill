import AppKit
import RillCore

/// The one look shared by rill's transient UI (search bar, hints, and later the status pill
/// and toasts): small, rounded, translucent, monospaced.
@MainActor
enum Overlay {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    static let cornerRadius: CGFloat = 8
    static let fadeDuration: TimeInterval = 0.12

    static func panel() -> OverlayPanel { OverlayPanel() }

    static func label(_ text: String = "", color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func show(_ view: NSView) {
        guard view.isHidden || view.alphaValue < 1 else { return }
        view.alphaValue = 0
        view.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : fadeDuration
            view.animator().alphaValue = 1
        }
    }

    static func hide(_ view: NSView) {
        guard !view.isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : fadeDuration
            view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { if view.alphaValue == 0 { view.isHidden = true } }
        }
    }
}

/// The rounded backdrop of an overlay, in the material `[view] overlays` asks for (and
/// switched when it changes). Content goes on top as ordinary subviews.
@MainActor
final class OverlayPanel: NSView {
    private var material: NSView?
    private(set) var style: Config.OverlayStyle?
    /// Called with the style now in effect: once when set, and on every change.
    var onStyleChange: ((Config.OverlayStyle) -> Void)? {
        didSet { if let style { onStyleChange?(style) } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Overlay.cornerRadius
        layer?.masksToBounds = true
        applyStyle()
        NotificationCenter.default.addObserver(forName: .rillConfigDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyStyle() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Everything added on top of the material.
    var contentSubviews: [NSView] { subviews.filter { $0 !== material } }

    private func applyStyle() {
        let style = ConfigStore.shared.config.overlays
        guard style != self.style else { return }
        self.style = style
        material?.removeFromSuperview()

        let view: NSView
        switch style {
        case .blur:
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .withinWindow
            blur.state = .active
            view = blur
        case .glass:
            let glass = NSGlassEffectView()
            glass.cornerRadius = Overlay.cornerRadius
            view = glass
        }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: nil)
        material = view
        onStyleChange?(style)
    }
}
