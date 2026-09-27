/// Single-page mode: decides when trackpad or wheel scrolling pushed on past the page's
/// edge should turn the page.
///
/// Only a deliberate push counts: momentum after the fingers lift never turns a page, and a
/// gesture that turned one is spent, so the rest of it (and its momentum) is swallowed.
public struct Overscroll: Sendable {
    public enum Phase: Sendable {
        /// Fingers touched the trackpad: a new gesture.
        case began
        case changed
        case ended
        /// Momentum after the fingers lifted.
        case momentum
        /// A mouse wheel tick: no gesture around it.
        case wheel
    }

    public enum Outcome: Equatable, Sendable {
        /// Let the scroll view handle the event.
        case pass
        /// Drop the event: the gesture already turned the page.
        case swallow
        /// Turn the page by this many rows.
        case turn(Int)
    }

    /// How far (screen points) to push past the edge before the page turns.
    public let threshold: Double
    private var pushed = 0.0
    private var spent = false

    public init(threshold: Double = 60) {
        self.threshold = threshold
    }

    /// `delta` > 0 scrolls forward (down). `atStart` / `atEnd`: the viewport rests at the
    /// page's top / bottom edge.
    public mutating func feed(delta: Double, phase: Phase, atStart: Bool, atEnd: Bool) -> Outcome {
        switch phase {
        case .began:
            pushed = 0
            spent = false
            return .pass
        case .ended:
            pushed = 0
            return spent ? .swallow : .pass
        case .momentum:
            return spent ? .swallow : .pass
        case .changed, .wheel:
            if spent { return .swallow }
        }
        if delta > 0, atEnd {
            pushed = max(pushed, 0) + delta
        } else if delta < 0, atStart {
            pushed = min(pushed, 0) + delta
        } else if delta != 0 {
            pushed = 0
        }
        guard abs(pushed) >= threshold else { return .pass }
        let direction = pushed > 0 ? 1 : -1
        pushed = 0
        // A wheel has no gesture to spend; landing away from the edge makes it scroll the new page first.
        if phase == .changed { spent = true }
        return .turn(direction)
    }
}
