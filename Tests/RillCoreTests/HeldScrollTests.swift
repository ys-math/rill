import Testing
@testable import RillCore

struct HeldScrollTests {
    @Test func acceleratesLinearlyToFullSpeed() {
        var held = HeldScroll(speed: 1000, accelTime: 0.5, decelTime: 0.2, direction: 1)
        #expect(abs(held.step(0.25) - 62.5) < 1e-9)
        #expect(abs(held.velocity - 500) < 1e-9)
        #expect(abs(held.step(0.25) - 187.5) < 1e-9)
        #expect(abs(held.velocity - 1000) < 1e-9)
        #expect(abs(held.step(0.1) - 100) < 1e-9)
        #expect(held.velocity == 1000)
    }

    @Test func aFrameThatReachesFullSpeedCruisesForTheRest() {
        var held = HeldScroll(speed: 1000, accelTime: 0.1, decelTime: 0.2, direction: 1)
        // 0.1 s ramping (50 pt), then 0.1 s at full speed (100 pt).
        #expect(abs(held.step(0.2) - 150) < 1e-9)
        #expect(held.velocity == 1000)
    }

    @Test func releaseCoastsToAStopInDecelTime() {
        var held = HeldScroll(speed: 1000, accelTime: 0, decelTime: 0.2, direction: -1)
        _ = held.step(0.1)
        held.release()
        var distance = held.step(0.15)
        #expect(!held.isStopped)
        distance += held.step(0.1)
        #expect(held.isStopped)
        #expect(abs(distance - -100) < 1e-9)
        #expect(held.step(0.1) == 0)
    }

    @Test func aBriefPressAcceleratesFromRestThenBrakes() {
        var held = HeldScroll(speed: 1000, accelTime: 0.4, decelTime: 0.4, direction: 1)
        var distance = held.step(0.1)      // 0 → 250 pt/s: 12.5 pt
        held.release()
        distance += held.step(1)           // 250 → 0 pt/s in 0.1 s: 12.5 pt
        #expect(held.isStopped)
        #expect(abs(distance - 25) < 1e-9)
    }

    @Test func zeroTimesStartAndStopInstantly() {
        var held = HeldScroll(speed: 1000, accelTime: 0, decelTime: 0, direction: 1)
        #expect(abs(held.step(0.1) - 100) < 1e-9)
        held.release()
        #expect(held.step(0.1) == 0)
        #expect(held.isStopped)
    }

    @Test func reversingDeceleratesThenAcceleratesAtTheHoldRate() {
        var held = HeldScroll(speed: 1000, accelTime: 0.5, decelTime: 0.1, direction: 1)
        _ = held.step(1)
        held.hold(direction: -1)
        _ = held.step(0.5)
        #expect(abs(held.velocity) < 1e-9)
        _ = held.step(0.5)
        #expect(abs(held.velocity - -1000) < 1e-9)
    }

    @Test func startsFromACarriedVelocity() {
        var held = HeldScroll(speed: 1000, accelTime: 0.5, decelTime: 0.2, velocity: 500, direction: 1)
        _ = held.step(0.25)
        #expect(abs(held.velocity - 1000) < 1e-9)
    }

    @Test func hittingAnEdgeDropsTheSpeed() {
        var held = HeldScroll(speed: 1000, accelTime: 0, decelTime: 2, direction: 1)
        _ = held.step(0.1)
        held.release()
        held.hitEdge()
        #expect(held.isStopped)
        #expect(held.step(0.1) == 0)
    }
}
