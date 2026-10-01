/// Held-key scrolling: while the key is held, speed changes linearly toward full speed in
/// its direction, taking `accelTime` from rest; once released, it falls linearly to zero,
/// taking `decelTime` from full speed. Works in screen points, so it feels the same at any zoom.
public struct HeldScroll: Sendable {
    /// Full speed, screen points per second.
    public var speed: Double
    /// Seconds from rest to full speed while held (0: instantly).
    public var accelTime: Double
    /// Seconds from full speed to a stop after release (0: instantly).
    public var decelTime: Double
    /// Signed, screen points per second.
    public private(set) var velocity: Double
    /// +1 or -1 while the key is held, 0 once released.
    public private(set) var direction: Double

    public init(speed: Double, accelTime: Double, decelTime: Double, velocity: Double = 0, direction: Double) {
        self.speed = speed
        self.accelTime = accelTime
        self.decelTime = decelTime
        self.velocity = velocity
        self.direction = direction
    }

    public var isHeld: Bool { direction != 0 }
    /// Released and at rest: nothing more to do.
    public var isStopped: Bool { direction == 0 && velocity == 0 }

    public mutating func hold(direction: Double) { self.direction = direction }
    public mutating func release() { direction = 0 }
    /// The viewport ran into the document's edge: there's nothing left to push against.
    public mutating func hitEdge() { velocity = 0 }

    /// Advances `dt` seconds and returns the distance moved (screen points), exactly: a frame
    /// that reaches the target speed moves at it for the rest of the frame.
    public mutating func step(_ dt: Double) -> Double {
        let target = direction * speed
        let change = target - velocity
        guard change != 0 else { return velocity * dt }
        let time = isHeld ? accelTime : decelTime
        let rate = time > 0 ? speed / time : .infinity
        let reach = abs(change) / rate
        if reach > dt {
            let next = velocity + (change > 0 ? rate : -rate) * dt
            defer { velocity = next }
            return (velocity + next) / 2 * dt
        }
        defer { velocity = target }
        return (velocity + target) / 2 * reach + target * (dt - reach)
    }
}
