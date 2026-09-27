import CoreGraphics
import Testing
@testable import RillCore

struct SpreadLayoutTests {
    let page = CGSize(width: 600, height: 800)

    func layout(_ count: Int, _ spread: PageLayout.Spread, trims: [CGRect]? = nil) -> PageLayout {
        PageLayout(pageSizes: Array(repeating: page, count: count), trims: trims, spread: spread, gap: 10, margin: 20)
    }

    @Test func pairsSitSideBySide() {
        let l = layout(5, .pairs)
        #expect(l.rows == [0...1, 2...3, 4...4])
        #expect(l.size == CGSize(width: 20 + 600 + 10 + 600 + 20, height: 20 + 3 * 800 + 2 * 10 + 20))
        #expect(l.pageFrames[0] == CGRect(x: 20, y: 20, width: 600, height: 800))
        #expect(l.pageFrames[1] == CGRect(x: 630, y: 20, width: 600, height: 800))
        #expect(l.pageFrames[2].minY == 830)
        // A last odd page stays on the left.
        #expect(l.pageFrames[4].minX == 20)
    }

    @Test func bookPutsTheFirstPageOnTheRight() {
        let l = layout(4, .book)
        #expect(l.rows == [0...0, 1...2, 3...3])
        #expect(l.pageFrames[0].minX == 630)
        #expect(l.pageFrames[1].minX == 20)
        #expect(l.pageFrames[2].minX == 630)
        #expect(l.pageFrames[3].minX == 20)
    }

    @Test func findsRowsAndPages() {
        let l = layout(5, .pairs)
        #expect(l.rowIndex(atY: 825) == 0)
        #expect(l.rowIndex(atY: 830) == 1)
        #expect(l.rowIndex(ofPage: 3) == 1)
        #expect(l.rowIndex(ofPage: 4) == 2)
        #expect(l.pageIndex(atY: 900) == 2)
        #expect(l.pageIndex(at: CGPoint(x: 700, y: 900)) == 3)
        #expect(l.pageIndex(at: CGPoint(x: 625, y: 900)) == 2) // in the gutter: the nearer page
        #expect(l.pages(inYRange: 500, 900) == 0...3)
        #expect(l.topOffset(ofPage: 3) == 825)
    }

    @Test func fitsTheWholeSpread() {
        let l = layout(2, .pairs)
        #expect(l.fitWidthMagnification(viewportWidth: 1210 + 32, inset: 16) == 1)
        #expect(l.fitPageMagnification(page: 1, viewport: CGSize(width: 1242, height: 5000), inset: 16) == 1)
    }

    @Test func positionsUseTheRowsFirstPage() {
        let l = layout(4, .pairs)
        let position = l.position(atY: 1230)
        #expect(position.page == 2)
        #expect(l.y(for: position) == 1230)
    }

    @Test func trimmedPagesShowOnlyTheirTrim() {
        let trim = CGRect(x: 100, y: 50, width: 400, height: 700)
        let l = layout(2, .off, trims: [trim, trim])
        #expect(l.size.width == 440)
        #expect(l.pageFrames[0] == CGRect(x: 20, y: 20, width: 400, height: 700))
        #expect(l.pageFrames[1].minY == 730)
        // Page coordinates are still the untrimmed page's.
        #expect(l.origin(ofPage: 0) == CGPoint(x: -80, y: -30))
        #expect(l.pagePoint(CGPoint(x: 20, y: 20), onPage: 0) == CGPoint(x: 100, y: 50))
    }

    @Test func spreadMeetsAtTheSpineWithDifferentWidths() {
        let l = layout(2, .pairs, trims: [CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 0, y: 0, width: 300, height: 800)])
        #expect(l.pageFrames[0].maxX + 10 == l.pageFrames[1].minX)
        #expect(l.size.width == 850) // 20 + 500 + 10 + 300 + 20
    }
}

struct TrimTests {
    @Test func findsInkInABitmap() {
        // 6×4 gray, one dark pixel at (1, 1) and one at (4, 2).
        var pixels = [UInt8](repeating: 255, count: 24)
        pixels[1 * 6 + 1] = 0
        pixels[2 * 6 + 4] = 100
        let box = pixels.withUnsafeBytes {
            ContentBounds.find(in: $0, width: 6, height: 4, bytesPerRow: 6, bytesPerPixel: 1)
        }
        #expect(box == CGRect(x: 1, y: 1, width: 4, height: 2))
    }

    @Test func blankBitmapHasNoContent() {
        let pixels = [UInt8](repeating: 250, count: 16)
        #expect(pixels.withUnsafeBytes { ContentBounds.find(in: $0, width: 2, height: 2, bytesPerRow: 8, bytesPerPixel: 4) } == nil)
    }

    @Test func alphaIsIgnored() {
        // BGRA: white with alpha 0 isn't ink.
        let pixels: [UInt8] = [255, 255, 255, 0]
        #expect(pixels.withUnsafeBytes { ContentBounds.find(in: $0, width: 1, height: 1, bytesPerRow: 4, bytesPerPixel: 4) } == nil)
    }

    @Test func oddAndEvenPagesAreTrimmedSeparately() {
        let size = CGSize(width: 600, height: 800)
        let profile = TrimProfile(contentBoxes: [
            CGRect(x: 150, y: 100, width: 350, height: 600),
            CGRect(x: 100, y: 100, width: 350, height: 600),
            CGRect(x: 150, y: 90, width: 350, height: 500),
            nil,
        ], pageSizes: Array(repeating: size, count: 4), padding: 10)
        let trims = profile.trims(for: Array(repeating: size, count: 5))
        #expect(trims[0] == CGRect(x: 140, y: 80, width: 370, height: 630))
        #expect(trims[1] == CGRect(x: 90, y: 90, width: 370, height: 620))
        #expect(trims[2] == trims[0])
        #expect(trims[3] == trims[1]) // a blank page takes its group's trim
        #expect(trims[4] == trims[0]) // so does a page added since
    }

    @Test func paddingStaysOnThePageAndOtherSizesShowWhole() {
        let profile = TrimProfile(contentBoxes: [CGRect(x: 2, y: 2, width: 596, height: 796)],
                                  pageSizes: [CGSize(width: 600, height: 800)], padding: 10)
        let trims = profile.trims(for: [CGSize(width: 600, height: 800), CGSize(width: 800, height: 600)])
        #expect(trims[0] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(trims[1] == CGRect(x: 0, y: 0, width: 800, height: 600))
    }
}
