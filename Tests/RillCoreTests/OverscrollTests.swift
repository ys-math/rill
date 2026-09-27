import Testing
@testable import RillCore

struct OverscrollTests {
    @Test func pushingPastTheBottomTurnsForward() {
        var over = Overscroll(threshold: 60)
        #expect(over.feed(delta: 0, phase: .began, atStart: false, atEnd: true) == .pass)
        #expect(over.feed(delta: 30, phase: .changed, atStart: false, atEnd: true) == .pass)
        #expect(over.feed(delta: 30, phase: .changed, atStart: false, atEnd: true) == .turn(1))
        // The rest of the gesture and its momentum are spent.
        #expect(over.feed(delta: 30, phase: .changed, atStart: true, atEnd: false) == .swallow)
        #expect(over.feed(delta: 0, phase: .ended, atStart: true, atEnd: false) == .swallow)
        #expect(over.feed(delta: 30, phase: .momentum, atStart: true, atEnd: false) == .swallow)
        // A new gesture scrolls normally.
        #expect(over.feed(delta: 0, phase: .began, atStart: true, atEnd: false) == .pass)
        #expect(over.feed(delta: 30, phase: .changed, atStart: true, atEnd: false) == .pass)
    }

    @Test func pushingPastTheTopTurnsBack() {
        var over = Overscroll(threshold: 60)
        _ = over.feed(delta: 0, phase: .began, atStart: true, atEnd: false)
        #expect(over.feed(delta: -40, phase: .changed, atStart: true, atEnd: false) == .pass)
        #expect(over.feed(delta: -40, phase: .changed, atStart: true, atEnd: false) == .turn(-1))
    }

    @Test func scrollingWithinThePageDoesNotCount() {
        var over = Overscroll(threshold: 60)
        _ = over.feed(delta: 0, phase: .began, atStart: false, atEnd: false)
        #expect(over.feed(delta: 100, phase: .changed, atStart: false, atEnd: false) == .pass)
        #expect(over.feed(delta: 40, phase: .changed, atStart: false, atEnd: true) == .pass)
        // Backing off resets the push.
        #expect(over.feed(delta: -5, phase: .changed, atStart: false, atEnd: false) == .pass)
        #expect(over.feed(delta: 40, phase: .changed, atStart: false, atEnd: true) == .pass)
    }

    @Test func momentumNeverTurns() {
        var over = Overscroll(threshold: 60)
        _ = over.feed(delta: 0, phase: .ended, atStart: false, atEnd: true)
        #expect(over.feed(delta: 500, phase: .momentum, atStart: false, atEnd: true) == .pass)
    }

    @Test func wheelTicksAccumulateAndKeepTurning() {
        var over = Overscroll(threshold: 60)
        #expect(over.feed(delta: 20, phase: .wheel, atStart: false, atEnd: true) == .pass)
        #expect(over.feed(delta: 20, phase: .wheel, atStart: false, atEnd: true) == .pass)
        #expect(over.feed(delta: 20, phase: .wheel, atStart: false, atEnd: true) == .turn(1))
        #expect(over.feed(delta: 20, phase: .wheel, atStart: false, atEnd: true) == .pass)
    }
}
