import Foundation
import Testing
@testable import RillCore

struct ChangeDetectorTests {
    @Test func identicalPagesHaveNoChanges() {
        #expect(ChangeDetector.changedBands(old: [1, 2, 3], new: [1, 2, 3]).isEmpty)
    }

    @Test func insertionMarksOnlyNewRows() {
        // A paragraph (rows 7, 8) added above content that moves down.
        let old: [UInt64] = [1, 2, 3, 4, 5]
        let new: [UInt64] = [1, 2, 7, 8, 3, 4, 5]
        #expect(ChangeDetector.changedBands(old: old, new: new) == [2..<4])
    }

    @Test func editedLineIsMarked() {
        #expect(ChangeDetector.changedBands(old: [1, 2, 3, 4], new: [1, 9, 3, 4]) == [1..<2])
    }

    @Test func deletionIsAnEmptyBandWhereItHappened() {
        #expect(ChangeDetector.changedBands(old: [1, 2, 3, 4], new: [1, 4]) == [1..<1])
    }

    @Test func nearbyChangesMerge() {
        let old: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let new: [UInt64] = [1, 20, 3, 21, 5, 6, 7, 8, 9, 30]
        #expect(ChangeDetector.changedBands(old: old, new: new, mergeGap: 1) == [1..<4, 9..<10])
    }

    @Test func linesMovedAcrossAPageStillMatch() {
        // The whole visible stretch as one sequence: an inserted line pushes the rest along.
        let old = ["a", "b", "c", "d"]
        let new = ["a", "NEW", "b", "c", "d"]
        #expect(ChangeDetector.changedBands(old: old, new: new) == [1..<2])
    }
}

struct VisualMotionTests {
    // Page 0: "one two\nthree"  lines [0,8) [8,13); words one(0,3) two(4,3) three(8,5)
    // Page 1: "four five"       line [0,9); words four(0,4) five(5,4)
    let pages = [
        PageText(length: 13, lines: [NSRange(location: 0, length: 8), NSRange(location: 8, length: 5)],
                 words: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3), NSRange(location: 8, length: 5)]),
        PageText(length: 9, lines: [NSRange(location: 0, length: 9)],
                 words: [NSRange(location: 0, length: 4), NSRange(location: 5, length: 4)]),
    ]
    func move(_ motion: VisualMotion, _ page: Int, _ index: Int, count: Int = 1) -> TextPosition {
        motion.apply(to: TextPosition(page: page, index: index), count: count, pageCount: pages.count) { pages[$0] }
    }

    @Test func characters() {
        #expect(move(.right, 0, 0) == TextPosition(page: 0, index: 1))
        #expect(move(.right, 0, 12) == TextPosition(page: 1, index: 0))   // on to the next page
        #expect(move(.left, 1, 0) == TextPosition(page: 0, index: 12))
        #expect(move(.left, 0, 0) == TextPosition(page: 0, index: 0))     // start of document
    }

    @Test func words() {
        #expect(move(.wordForward, 0, 0) == TextPosition(page: 0, index: 4))
        #expect(move(.wordForward, 0, 0, count: 2) == TextPosition(page: 0, index: 8))
        #expect(move(.wordForward, 0, 9) == TextPosition(page: 1, index: 0))
        #expect(move(.wordBackward, 0, 6) == TextPosition(page: 0, index: 4))
        #expect(move(.wordBackward, 1, 0) == TextPosition(page: 0, index: 8))
        #expect(move(.wordEnd, 0, 0) == TextPosition(page: 0, index: 2))
        #expect(move(.wordEnd, 0, 2) == TextPosition(page: 0, index: 6))
    }

    @Test func lineEnds() {
        #expect(move(.lineStart, 0, 10) == TextPosition(page: 0, index: 8))
        #expect(move(.lineEnd, 0, 1) == TextPosition(page: 0, index: 7))
        #expect(move(.lineEnd, 0, 9) == TextPosition(page: 0, index: 12))
    }

    @Test func ordering() {
        #expect(TextPosition(page: 0, index: 50) < TextPosition(page: 1, index: 0))
    }
}
