import AppKit
import RillCore

/// What shows through around the pages when `[view] background` isn't "solid": the desktop
/// and windows behind rill, blurred or under Liquid Glass. Sits behind the scroll view, which
/// stops drawing its gray so this shows through; the pages themselves stay opaque.
@MainActor
final class Backdrop: NSView {
    private var material: NSView?
    private(set) var background = Config.Background.solid

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Switches to `background`, making `window` see-through (or opaque again) to match.
    func apply(_ background: Config.Background, scrollView: NSScrollView, window: NSWindow?) {
        if background != self.background || (material == nil && background != .solid) {
            self.background = background
            material?.removeFromSuperview()
            material = Self.makeMaterial(for: background)
            if let material {
                material.frame = bounds
                material.autoresizingMask = [.width, .height]
                addSubview(material)
            }
        }
        scrollView.drawsBackground = background == .solid
        guard let window else { return }
        window.isOpaque = background == .solid
        window.backgroundColor = background == .solid ? .windowBackgroundColor : .clear
    }

    private static func makeMaterial(for background: Config.Background) -> NSView? {
        switch background {
        case .solid:
            return nil
        case .blur:
            let blur = NSVisualEffectView()
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            // rill usually sits beside the editor, inactive; don't go flat gray then.
            blur.state = .active
            return blur
        case .glass:
            return NSGlassEffectView()
        }
    }
}
