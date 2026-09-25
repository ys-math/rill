import Foundation

/// A critically damped spring, stepped with its exact closed-form solution so it stays
/// stable at any frame interval. Critical damping never overshoots.
public struct Spring: Sendable {
    /// Natural frequency (1/s). ~50 settles a 1000 pt move in ~220 ms and shorter moves sooner.
    public var omega: Double
    public var position: Double
    public var velocity: Double
    public var target: Double
    /// Close enough to stop: defaults suit on-screen points (sub-pixel, < 0.1 pt per frame).
    public var tolerance: Double

    public init(omega: Double = 50, position: Double, velocity: Double = 0, target: Double, tolerance: Double = 0.25) {
        self.omega = omega
        self.position = position
        self.velocity = velocity
        self.target = target
        self.tolerance = tolerance
    }

    public var isSettled: Bool {
        abs(position - target) < tolerance && abs(velocity) < tolerance * 40
    }

    public mutating func step(_ dt: Double) {
        let e = position - target
        let b = velocity + omega * e
        let decay = exp(-omega * dt)
        position = target + (e + b * dt) * decay
        velocity = (velocity - omega * b * dt) * decay
        if isSettled {
            position = target
            velocity = 0
        }
    }
}
