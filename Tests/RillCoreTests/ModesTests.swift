import CoreGraphics
import Foundation
import Testing
@testable import RillCore

struct JumpListTests {
    func list() -> JumpList<Int> { JumpList(isSame: { $0 == $1 }) }

    @Test func backAndForward() {
        var jumps = list()
        jumps.record(1)  // at 1, jumped to 2
        jumps.record(2)  // at 2, jumped to 3
        #expect(jumps.back(from: 3) == 2)
        #expect(jumps.back(from: 2) == 1)
        #expect(jumps.back(from: 1) == nil)
        #expect(jumps.forward() == 2)
        #expect(jumps.forward() == 3)  // the position we left when first going back
        #expect(jumps.forward() == nil)
    }

    @Test func newJumpDropsForwardHistory() {
        var jumps = list()
        jumps.record(1)
        jumps.record(2)
        _ = jumps.back(from: 3)          // at 2
        jumps.record(2)                  // jump from 2 to 9
        #expect(jumps.forward() == nil)
        #expect(jumps.back(from: 9) == 2)
        #expect(jumps.back(from: 2) == 1)
    }

    @Test func consecutiveDuplicatesCollapse() {
        var jumps = list()
        jumps.record(1)
        jumps.record(1)
        #expect(jumps.count == 1)
    }

    @Test func goingBackFromTheLastRecordedSpotSkipsIt() {
        var jumps = list()
        jumps.record(1)
        jumps.record(2)
        // Returned to 2 by other means; ⌃o should go to 1, not "back" to 2.
        #expect(jumps.back(from: 2) == 1)
    }

    @Test func respectsCapacity() {
        var jumps = JumpList<Int>(capacity: 3, isSame: { $0 == $1 })
        for i in 0..<10 { jumps.record(i) }
        #expect(jumps.count == 3)
        #expect(jumps.lastJumpOrigin == 9)
    }
}

struct HintLabelTests {
    @Test func singleKeysWhenTheyFit() {
        #expect(HintLabels.make(3) == ["a", "s", "d"])
    }

    @Test func prefixFreeWhenLonger() {
        let labels = HintLabels.make(30)
        #expect(labels.count == 30)
        #expect(Set(labels).count == 30)
        #expect(labels.allSatisfy { $0.count == 2 })
        for a in labels { for b in labels where a != b { #expect(!b.hasPrefix(a)) } }
    }

    @Test func noneForZero() {
        #expect(HintLabels.make(0).isEmpty)
    }
}

struct SearchTests {
    @Test func smartCase() {
        #expect(!SearchQuery("functor").isCaseSensitive)
        #expect(SearchQuery("Yoneda").isCaseSensitive)
        #expect(SearchQuery("functor").ranges(in: "Functor and functor").count == 2)
        #expect(SearchQuery("Functor").ranges(in: "Functor and functor") == [NSRange(location: 0, length: 7)])
    }

    @Test func nonOverlapping() {
        #expect(SearchQuery("aa").ranges(in: "aaaa").map(\.location) == [0, 2])
        #expect(SearchQuery("").ranges(in: "abc").isEmpty)
    }

    @Test func utf16Ranges() {
        // "圏論" is two UTF-16 units; the match after it starts at 3.
        #expect(SearchQuery("x").ranges(in: "圏論 x") == [NSRange(location: 3, length: 1)])
    }

    let matches = SearchNavigation.sorted([
        SearchMatch(page: 1, rect: CGRect(x: 10, y: 100, width: 20, height: 10)),
        SearchMatch(page: 0, rect: CGRect(x: 50, y: 300, width: 20, height: 10)),
        SearchMatch(page: 0, rect: CGRect(x: 10, y: 302, width: 20, height: 10)),  // same line, further left
        SearchMatch(page: 0, rect: CGRect(x: 10, y: 50, width: 20, height: 10)),
    ])

    @Test func readingOrder() {
        #expect(matches.map { [$0.page, Int($0.rect.minY)] } == [[0, 50], [0, 302], [0, 300], [1, 100]])
    }

    @Test func firstMatchFromPosition() {
        #expect(SearchNavigation.firstIndex(in: matches, fromPage: 0, y: 200, forward: true) == 1)
        #expect(SearchNavigation.firstIndex(in: matches, fromPage: 0, y: 200, forward: false) == 0)
        #expect(SearchNavigation.firstIndex(in: matches, fromPage: 5, y: 0, forward: true) == 0)       // wraps
        #expect(SearchNavigation.firstIndex(in: matches, fromPage: 0, y: 0, forward: false) == 3)      // wraps
        #expect(SearchNavigation.firstIndex(in: [], fromPage: 0, y: 0, forward: true) == nil)
    }

    @Test func stepping() {
        #expect(SearchNavigation.step(from: 3, by: 1, total: 4) == 0)
        #expect(SearchNavigation.step(from: 0, by: -1, total: 4) == 3)
        #expect(SearchNavigation.step(from: 1, by: 6, total: 4) == 3)
    }
}

struct MarksPersistenceTests {
    @Test func oldStateWithoutMarksStillLoads() throws {
        let json = #"{"position":{"page":2,"offset":0.5},"x":0,"zoom":{"fitWidth":{}},"lastOpened":"2026-09-25T04:51:32Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(DocumentState.self, from: Data(json.utf8))
        #expect(state.position == PagePosition(page: 2, offset: 0.5))
        #expect(state.marks.isEmpty)
    }

    @Test func marksRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rill-marks-\(UUID().uuidString)/d.json")
        let store = DocumentStateStore(fileURL: url)
        store.set(DocumentState(position: PagePosition(page: 0, offset: 0), zoom: .fitWidth,
                                marks: ["a": PagePosition(page: 4, offset: 0.25)]), forPath: "/x.pdf")
        try store.save()
        #expect(DocumentStateStore(fileURL: url).state(forPath: "/x.pdf")?.marks["a"] == PagePosition(page: 4, offset: 0.25))
    }
}

struct PageGeometryTests {
    let crop = CGRect(x: 10, y: 20, width: 600, height: 800)

    @Test func unrotatedFlipsY() {
        let g = PageGeometry(cropBox: crop, rotation: 0)
        #expect(g.displayPoint(CGPoint(x: 10, y: 820)) == .zero)            // top-left corner
        #expect(g.displayRect(CGRect(x: 110, y: 700, width: 50, height: 20)) == CGRect(x: 100, y: 100, width: 50, height: 20))
    }

    @Test func rotatedSizesSwap() {
        #expect(PageGeometry(cropBox: crop, rotation: 90).displaySize == CGSize(width: 800, height: 600))
        #expect(PageGeometry(cropBox: crop, rotation: -90).rotation == 270)
    }

    @Test func quarterTurnMovesBottomLeftToTopLeft() {
        // Rotating a page clockwise by 90° puts its bottom-left corner at the top-left.
        #expect(PageGeometry(cropBox: crop, rotation: 90).displayPoint(CGPoint(x: 10, y: 20)) == .zero)
    }

    @Test func roundTripsForEveryRotation() {
        for rotation in [0, 90, 180, 270] {
            let g = PageGeometry(cropBox: crop, rotation: rotation)
            for p in [CGPoint(x: 10, y: 20), CGPoint(x: 123, y: 456), CGPoint(x: 610, y: 820)] {
                let back = g.pagePoint(g.displayPoint(p))
                #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
                let d = g.displayPoint(p)
                #expect(d.x >= 0 && d.y >= 0 && d.x <= g.displaySize.width && d.y <= g.displaySize.height)
            }
        }
    }
}
