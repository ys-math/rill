import Testing
@testable import RillCore

struct IndexEntryTests {
    @Test func termBeforePageNumbers() {
        #expect(IndexEntry.term(ofLine: "compact set, 12") == "compact set")
        #expect(IndexEntry.term(ofLine: "Banach space, 3, 17–19, 40ff.") == "Banach space")
        #expect(IndexEntry.term(ofLine: "  sequentially, xiv, 2") == "sequentially")
        #expect(IndexEntry.term(ofLine: "Hahn–Banach theorem . . . . 55") == "Hahn–Banach theorem")
    }

    @Test func termKeepsCommasInside() {
        #expect(IndexEntry.term(ofLine: "set, compact, 12") == "set, compact")
    }

    @Test func linesWithoutPageNumbersAreNotEntries() {
        #expect(IndexEntry.term(ofLine: "compact set") == nil)
        #expect(IndexEntry.term(ofLine: "see also Banach space") == nil)
        #expect(IndexEntry.term(ofLine: "12") == nil)
        #expect(IndexEntry.term(ofLine: "Theorem 3.2 shows that") == nil)
    }

    @Test func pageNumbers() {
        #expect(IndexEntry.isPageNumber("12"))
        #expect(IndexEntry.isPageNumber("34–35"))
        #expect(IndexEntry.isPageNumber("xiv"))
        #expect(IndexEntry.isPageNumber("12,"))
        #expect(!IndexEntry.isPageNumber("Theorem 3"))
        #expect(!IndexEntry.isPageNumber("[4]"))
    }

    @Test func searchTermsBestFirst() {
        #expect(IndexEntry.searchTerms(term: "sequentially", parent: "compact set")
            == ["sequentially compact set", "compact set sequentially", "sequentially", "compact set", "compact"])
        #expect(IndexEntry.searchTerms(term: "Banach space", parent: nil) == ["Banach space", "Banach", "space"])
    }
}
