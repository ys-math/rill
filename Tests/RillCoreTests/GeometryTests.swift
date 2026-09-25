import CoreGraphics
import Testing
@testable import RillCore

struct SpringTests {
    @Test func settlesWithinBudgetWithoutOvershoot() {
        var s = Spring(position: 0, target: 1000)
        var t = 0.0
        while !s.isSettled && t < 1 {
            s.step(1.0 / 120)
            t += 1.0 / 120
            #expect(s.position <= 1000)
        }
        #expect(s.position == 1000)
        #expect(t <= 0.25)
    }

    @Test func stableAtLongFrames() {
        var s = Spring(position: 0, target: 500)
        for _ in 0..<20 { s.step(0.1) }
        #expect(s.isSettled)
    }

    @Test func retargetingKeepsVelocity() {
        var s = Spring(position: 0, target: 100)
        s.step(0.02)
        let v = s.velocity
        s.target = 300
        #expect(s.velocity == v)
        s.step(0.02)
        #expect(s.position > 0)
    }
}

struct PageLayoutTests {
    let layout = PageLayout(pageSizes: [CGSize(width: 600, height: 800), CGSize(width: 400, height: 300)], gap: 10, margin: 20)

    @Test func stacksAndCentersPages() {
        #expect(layout.size == CGSize(width: 640, height: 20 + 800 + 10 + 300 + 20))
        #expect(layout.pageFrames[0] == CGRect(x: 20, y: 20, width: 600, height: 800))
        #expect(layout.pageFrames[1] == CGRect(x: 120, y: 830, width: 400, height: 300))
    }

    @Test func findsPages() {
        #expect(layout.pageIndex(atY: 0) == 0)
        #expect(layout.pageIndex(atY: 825) == 0)  // gap belongs to the page above
        #expect(layout.pageIndex(atY: 830) == 1)
        #expect(layout.pageIndex(atY: 99999) == 1)
        #expect(layout.pages(inYRange: 500, 900) == 0...1)
        #expect(layout.pages(inYRange: 2000, 3000) == nil)
    }

    @Test func pageTopOffsets() {
        #expect(layout.topOffset(ofPage: 0) == 15)
        #expect(layout.topOffset(ofPage: 1) == 825)
        #expect(layout.topOffset(ofPage: 9) == 825)
    }

    @Test func fitMagnifications() {
        #expect(layout.fitWidthMagnification(viewportWidth: 632, inset: 16) == 1)
        let fit = layout.fitPageMagnification(page: 0, viewport: CGSize(width: 2000, height: 820), inset: 16)
        #expect(fit == 1)
    }
}

struct TileGridTests {
    @Test func levelsRoundUp() {
        #expect(TileGrid.level(forPixelsPerPoint: 1) == 0)
        #expect(TileGrid.level(forPixelsPerPoint: 2) == 4)
        #expect(TileGrid.level(forPixelsPerPoint: 2.01) == 5)
        #expect(TileGrid.scale(forLevel: TileGrid.level(forPixelsPerPoint: 3.3)) >= 3.3)
        #expect(TileGrid.level(forPixelsPerPoint: 1000) == TileGrid.maxLevel)
    }

    @Test func coversVisibleRegion() {
        // Level 0: 1 px/pt, so tiles are 512 pt.
        let page = CGSize(width: 600, height: 800)
        let keys = TileGrid.keys(page: 3, level: 0, pageSize: page, visible: CGRect(x: 0, y: 500, width: 600, height: 100))
        #expect(Set(keys) == [
            TileKey(page: 3, level: 0, column: 0, row: 0), TileKey(page: 3, level: 0, column: 1, row: 0),
            TileKey(page: 3, level: 0, column: 0, row: 1), TileKey(page: 3, level: 0, column: 1, row: 1),
        ])
    }

    @Test func edgeTilesAreClipped() {
        let page = CGSize(width: 600, height: 800)
        #expect(TileGrid.rect(of: TileKey(page: 0, level: 0, column: 1, row: 1), pageSize: page)
                == CGRect(x: 512, y: 512, width: 88, height: 288))
    }

    @Test func invisiblePageHasNoTiles() {
        #expect(TileGrid.keys(page: 0, level: 0, pageSize: CGSize(width: 100, height: 100),
                              visible: CGRect(x: 0, y: 200, width: 100, height: 100)).isEmpty)
    }
}
