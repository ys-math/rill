import AppKit
import QuartzCore
import RillCore

/// Drives all programmatic movement of a scroll view from its display link:
/// spring-animated scrolls and jumps, held-key continuous scrolling, and animated zoom.
@MainActor
final class Motion {
    enum Axis { case horizontal, vertical }

    /// Held-key scroll speed, in screen points per second.
    static let continuousSpeed: Double = 1300
    /// Time constant of the held-key speed ramp (~80 ms to full speed).
    static let continuousRamp: Double = 0.03
    /// A key released sooner than this was a tap: finish exactly one step instead of gliding.
    static let tapThreshold: CFTimeInterval = 0.2
    /// Jumps farther than this many viewports crossfade instead of scrolling the whole way.
    static let longJumpViewports: CGFloat = 3

    private unowned let scrollView: NSScrollView
    private var clip: NSClipView { scrollView.contentView }
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    private var xSpring: Spring?
    private var ySpring: Spring?
    private var zoom: ZoomAnimation?
    private var continuous: Continuous?

    /// Called after every frame that moved or zoomed; `settled` is false while zoom is animating.
    var onFrame: ((_ settled: Bool) -> Void)?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var isZooming: Bool { zoom != nil }

    /// Current scroll origin (document points).
    var origin: CGPoint { clip.bounds.origin }
    /// Viewport size in document points.
    var viewport: CGSize { clip.bounds.size }

    // MARK: - Commands

    /// Scroll by a delta (document points). Repeated calls accumulate onto the running target.
    func scroll(by delta: CGFloat, axis: Axis) {
        zoom = nil
        switch axis {
        case .vertical:
            let base = ySpring?.target ?? origin.y
            animate(y: base + delta)
        case .horizontal:
            let base = xSpring?.target ?? origin.x
            animate(x: base + delta)
        }
    }

    /// Scroll so the document point `y` is at the top of the viewport. Long jumps crossfade.
    func jump(toY y: CGFloat) {
        zoom = nil
        continuous = nil
        let target = clampY(y)
        let distance = target - origin.y
        if reduceMotion {
            if abs(distance) > 0.5 { set(origin: CGPoint(x: origin.x, y: target)); crossfade(duration: 0.12) }
            return
        }
        if abs(distance) > viewport.height * Self.longJumpViewports {
            // Land just short of the target and let the spring cover the last stretch.
            let lead = viewport.height * 0.12 * (distance > 0 ? 1 : -1)
            set(origin: CGPoint(x: origin.x, y: target - lead))
            ySpring = nil
            crossfade(duration: 0.2)
        }
        animate(y: target)
    }

    /// Zoom to `magnification`, keeping document point `anchor` at viewport point `viewPoint`
    /// by the end. If `finalAnchor` is given, the anchor glides there during the zoom.
    func zoom(to magnification: CGFloat, anchor: CGPoint, finalAnchor: CGPoint? = nil, viewPoint: CGPoint) {
        xSpring = nil
        ySpring = nil
        continuous = nil
        let target = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
        let animation = ZoomAnimation(from: scrollView.magnification, to: target,
                                      anchor: anchor, finalAnchor: finalAnchor ?? anchor, viewPoint: viewPoint)
        if reduceMotion {
            apply(animation, progress: 1)
            onFrame?(true)
            return
        }
        zoom = animation
        start()
    }

    /// Begin scrolling continuously while a key is held.
    func beginContinuous(axis: Axis, direction: CGFloat, step: CGFloat) {
        zoom = nil
        let spring = axis == .vertical ? ySpring : xSpring
        let position = axis == .vertical ? origin.y : origin.x
        continuous = Continuous(axis: axis, direction: direction, step: step, startPosition: position,
                                startTime: CACurrentMediaTime(), velocity: spring?.velocity ?? 0)
        if axis == .vertical { ySpring = nil } else { xSpring = nil }
        start()
    }

    /// The held key was released: a tap finishes exactly one step, a hold glides to a stop.
    func endContinuous() {
        guard let c = continuous else { return }
        continuous = nil
        let position = c.axis == .vertical ? origin.y : origin.x
        let target: CGFloat
        if CACurrentMediaTime() - c.startTime < Self.tapThreshold {
            target = c.startPosition + c.direction * c.step
        } else {
            target = position + CGFloat(c.velocity) * 0.06
        }
        var spring = Spring(position: position, velocity: c.velocity, target: target)
        switch c.axis {
        case .vertical: spring.target = clampY(target); ySpring = spring
        case .horizontal: spring.target = clampX(target); xSpring = spring
        }
        start()
    }

    /// Stop everything immediately (the user grabbed the trackpad).
    func stop() {
        xSpring = nil
        ySpring = nil
        zoom = nil
        continuous = nil
    }

    // MARK: - Frame loop

    private func animate(x: CGFloat) {
        let target = clampX(x)
        if var s = xSpring { s.target = target; xSpring = s } else { xSpring = Spring(position: origin.x, target: target) }
        start()
    }

    private func animate(y: CGFloat) {
        let target = clampY(y)
        if var s = ySpring { s.target = target; ySpring = s } else { ySpring = Spring(position: origin.y, target: target) }
        start()
    }

    private func start() {
        if link == nil {
            let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(now - (lastTimestamp ?? link.timestamp), 1.0 / 240), 1.0 / 20)
        lastTimestamp = now

        var point = origin
        var zoomSettled = true

        if var z = zoom {
            z.progress.step(dt)
            apply(z, progress: z.progress.position)
            zoom = z.progress.isSettled ? nil : z
            zoomSettled = zoom == nil
            point = origin
        }

        if var c = continuous {
            let target = Self.continuousSpeed / Double(scrollView.magnification) * Double(c.direction)
            c.velocity += (target - c.velocity) * (1 - exp(-dt / Self.continuousRamp))
            continuous = c
            switch c.axis {
            case .vertical: point.y = clampY(point.y + CGFloat(c.velocity * dt))
            case .horizontal: point.x = clampX(point.x + CGFloat(c.velocity * dt))
            }
        }
        if var s = ySpring {
            s.step(dt)
            point.y = s.position
            ySpring = s.isSettled ? nil : s
        }
        if var s = xSpring {
            s.step(dt)
            point.x = s.position
            xSpring = s.isSettled ? nil : s
        }
        if point != origin { set(origin: point) }
        onFrame?(zoomSettled)

        if xSpring == nil, ySpring == nil, zoom == nil, continuous == nil {
            link.isPaused = true
            lastTimestamp = nil
        }
    }

    private func apply(_ z: ZoomAnimation, progress: Double) {
        let p = min(max(progress, 0), 1)
        let m = exp(log(z.from) + (log(z.to) - log(z.from)) * p)
        let anchor = CGPoint(x: z.anchor.x + (z.finalAnchor.x - z.anchor.x) * p,
                             y: z.anchor.y + (z.finalAnchor.y - z.anchor.y) * p)
        scrollView.magnification = m
        set(origin: CGPoint(x: anchor.x - z.viewPoint.x / m, y: anchor.y - z.viewPoint.y / m))
    }

    private func set(origin point: CGPoint) {
        clip.scroll(to: point)
        scrollView.reflectScrolledClipView(clip)
    }

    private func crossfade(duration: CFTimeInterval) {
        guard let layer = scrollView.documentView?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "crossfade")
    }

    private func clampY(_ y: CGFloat) -> CGFloat {
        let height = scrollView.documentView?.frame.height ?? 0
        return min(max(y, 0), max(height - viewport.height, 0))
    }

    private func clampX(_ x: CGFloat) -> CGFloat {
        let width = scrollView.documentView?.frame.width ?? 0
        guard width > viewport.width else { return origin.x }
        return min(max(x, 0), width - viewport.width)
    }
}

private struct ZoomAnimation {
    var from: CGFloat
    var to: CGFloat
    var anchor: CGPoint
    var finalAnchor: CGPoint
    /// Where the anchor sits in the viewport, in window points from the viewport's top-left.
    var viewPoint: CGPoint
    /// 0 → 1. A bit stiffer than scrolling: zoom should finish in ~150 ms.
    var progress = Spring(omega: 60, position: 0, target: 1, tolerance: 0.001)

    init(from: CGFloat, to: CGFloat, anchor: CGPoint, finalAnchor: CGPoint, viewPoint: CGPoint) {
        self.from = from
        self.to = to
        self.anchor = anchor
        self.finalAnchor = finalAnchor
        self.viewPoint = viewPoint
    }
}

private struct Continuous {
    var axis: Motion.Axis
    var direction: CGFloat
    var step: CGFloat
    var startPosition: CGFloat
    var startTime: CFTimeInterval
    var velocity: Double
}
