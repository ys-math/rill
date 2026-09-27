import Testing
@testable import RillCore

struct FuzzyTests {
    @Test func requiresCharactersInOrder() {
        #expect(Fuzzy.match("hom", in: "homological_algebra") != nil)
        #expect(Fuzzy.match("moh", in: "homological_algebra") == nil)
        #expect(Fuzzy.match("", in: "anything")?.score == 0)
    }

    @Test func wordStartsBeatScatteredLetters() {
        let initials = Fuzzy.match("ha", in: "homological_algebra.pdf")!
        let scattered = Fuzzy.match("ha", in: "the_character.pdf")!
        #expect(initials.score > scattered.score)
        #expect(initials.positions == [0, 12])
    }

    @Test func consecutiveRunsWin() {
        #expect(Fuzzy.match("cat", in: "category.pdf")!.score > Fuzzy.match("cat", in: "chapter_a_t.pdf")!.score)
    }

    @Test func picksTheBetterOfSeveralStarts() {
        // The "g" in "algebra" is not where "gal" should anchor; "galois" is.
        let m = Fuzzy.match("gal", in: "algebra/galois.pdf")!
        #expect(m.positions == [8, 9, 10])
    }

    @Test func smartCase() {
        #expect(Fuzzy.match("TeX", in: "latex.pdf") == nil)
        #expect(Fuzzy.match("tex", in: "LaTeX.pdf") != nil)
    }

    @Test func camelCaseAndNumbersAreWordStarts() {
        #expect(Fuzzy.isWordStart(Array("myPaper"), 2))
        #expect(Fuzzy.isWordStart(Array("ch02"), 2))
        #expect(!Fuzzy.isWordStart(Array("paper"), 2))
    }

    @Test func shorterCandidatesWinTies() {
        #expect(Fuzzy.match("rill", in: "rill.pdf")!.score > Fuzzy.match("rill", in: "rill-old-draft.pdf")!.score)
    }

    @Test func homeAbbreviation() {
        #expect(abbreviateHome("/Users/me/Papers/x.pdf", home: "/Users/me") == "~/Papers/x.pdf")
        #expect(abbreviateHome("/Users/meme/x.pdf", home: "/Users/me") == "/Users/meme/x.pdf")
        #expect(expandHome("~/Papers", home: "/Users/me") == "/Users/me/Papers")
        #expect(expandHome("/abs", home: "/Users/me") == "/abs")
    }
}

struct DistinguishingNameTests {
    @Test func uniqueNamesStayShort() {
        #expect(distinguishingNames(["/a/x.pdf", "/b/y.pdf"]) == ["x.pdf", "y.pdf"])
    }

    @Test func duplicatesGainTheirFolder() {
        #expect(distinguishingNames([
            "/m/tex/homological_algebra/main.pdf", "/m/tex/topology/main.pdf", "/m/pdf/topology.pdf",
        ]) == ["homological_algebra/main.pdf", "topology/main.pdf", "topology.pdf"])
    }

    @Test func goesAsDeepAsNeeded() {
        #expect(distinguishingNames(["/a/src/main.pdf", "/b/src/main.pdf", "/c/main.pdf"])
                == ["a/src/main.pdf", "b/src/main.pdf", "c/main.pdf"])
    }

    @Test func identicalPathsDoNotLoop() {
        #expect(distinguishingNames(["/a/x.pdf", "/a/x.pdf"]) == ["a/x.pdf", "a/x.pdf"])
    }
}
