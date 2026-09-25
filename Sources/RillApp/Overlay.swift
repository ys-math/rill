import AppKit

/// The one look shared by rill's transient UI (search bar, hints, and later the status pill
/// and toasts): small, rounded, translucent, monospaced.
@MainActor
enum Overlay {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    static let cornerRadius: CGFloat = 8
    static let fadeDuration: TimeInterval = 0.12

    static func panel() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

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
