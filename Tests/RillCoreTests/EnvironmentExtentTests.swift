import CoreGraphics
import Foundation
import Testing
@testable import RillCore

/// Text layouts of `Fixtures/environments/*.tex` as PDFKit reads them (display coordinates),
/// with the destinations of the links on their first page.
private struct Layout: Decodable {
    struct Page: Decodable { var lines: [Line] }
    struct Line: Decodable { var rect: [Double]; var text: String }
    struct Link: Decodable { var text: String; var page: Int; var anchor: [Double] }
    var pages: [Page]
    var links: [Link]

    static func load(_ name: String) throws -> Layout {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/environments"))
        return try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url))
    }

    func pieces(onPage page: Int) -> [TextPiece] {
        pages[page].lines.map {
            TextPiece(rect: CGRect(x: $0.rect[0], y: $0.rect[1], width: $0.rect[2], height: $0.rect[3]), text: $0.text)
        }
    }

    /// First and last line of the environment the `index`th link leads to.
    func environment(ofLink index: Int) throws -> (first: String, last: String) {
        let link = links[index]
        let pieces = pieces(onPage: link.page)
        let extent = try #require(EnvironmentExtent.extent(of: pieces, anchor: CGPoint(x: link.anchor[0], y: link.anchor[1]))).rect
        let inside = pieces.filter { extent.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) }.sorted { ($0.rect.maxY, $0.rect.minX) < ($1.rect.maxY, $1.rect.minX) }
        return (try #require(inside.first).text, try #require(inside.last).text)
    }
}

struct EnvironmentExtentTests {
    // amsart.tex links, in order: Theorem 2.2, Lemma 2.3, Definition 2.1, Remark 2.4, (1), (2), Section 2, [1].

    @Test func theoremWithDisplayedEquation() throws {
        let env = try Layout.load("amsart").environment(ofLink: 0)
        #expect(env.first.hasPrefix("Theorem 2.2."))
        #expect(env.last.hasPrefix("holds for all right triangles"))
    }

    @Test func oneLineLemmaStopsBeforeTheNextParagraph() throws {
        let env = try Layout.load("amsart").environment(ofLink: 1)
        #expect(env.first == "Lemma 2.3. Short lemma statement here.")
        #expect(env.last == env.first)
    }

    @Test func definitionWithDisplayAndSubscripts() throws {
        let env = try Layout.load("amsart").environment(ofLink: 2)
        #expect(env.first.hasPrefix("Definition 2.1."))
        #expect(env.last == "enough.")
    }

    @Test func remarkInUprightText() throws {
        let env = try Layout.load("amsart").environment(ofLink: 3)
        #expect(env.first.hasPrefix("Remark 2.4."))
        #expect(env.last.hasPrefix("that it wraps"))
    }

    @Test func equationIsJustTheDisplay() throws {
        let env = try Layout.load("amsart").environment(ofLink: 4)
        #expect(env.first.hasPrefix("(1)"))
        #expect(env.last == "= c2")
    }

    @Test func alignKeepsEveryRow() throws {
        let env = try Layout.load("amsart").environment(ofLink: 5)
        #expect(env.first.hasPrefix("(2)") || env.first.hasPrefix("x = y"))
        #expect(env.last == "(3)" || env.last == "u = v")
    }

    @Test func sectionShowsHeadingAndFirstParagraph() throws {
        let env = try Layout.load("amsart").environment(ofLink: 6)
        #expect(env.first == "2. Main")
        #expect(env.last.hasPrefix("Nulla ullamcorper"))
    }

    @Test func bibliographyEntryStopsAtTheNext() throws {
        let env = try Layout.load("amsart").environment(ofLink: 7)
        #expect(env.first.hasPrefix("[1] A. Author"))
        #expect(env.last == "1–20.")
    }

    // twocolumn.tex links: Theorem 1 (with a list), (1).

    @Test func theoremWithListInTwoColumns() throws {
        let env = try Layout.load("twocolumn").environment(ofLink: 0)
        #expect(env.first.hasPrefix("Theorem 1."))
        #expect(env.last == "In particular it holds.")
    }

    @Test func equationWithNumberOnTheRight() throws {
        let env = try Layout.load("twocolumn").environment(ofLink: 1)
        #expect(env.first == "a2 + b2")
        #expect(env.last == "= c2 (1)")
    }

    // jlreq.tex (Japanese, keytheorems with □ end marks) links: 定理 1.2, 定義 1.3, 注意 1.1, 定義 1.4.

    @Test func japaneseTheoremEndsAtItsMarkBeforeTheProof() throws {
        let env = try Layout.load("jlreq").environment(ofLink: 0)
        #expect(env.first.hasPrefix("定理 1.2"))
        #expect(env.last == "= F (A) となる. □")
    }

    @Test func japaneseDefinitionWithTaggedDisplay() throws {
        let env = try Layout.load("jlreq").environment(ofLink: 1)
        #expect(env.first.hasPrefix("定義 1.3"))
        #expect(env.last.hasPrefix("u が普遍元であるとき"))
    }

    @Test func oneLineJapaneseRemark() throws {
        let env = try Layout.load("jlreq").environment(ofLink: 2)
        #expect(env.first.hasPrefix("注意 1.1"))
        #expect(env.last == env.first)
    }

    @Test func japaneseDefinitionWithBulletList() throws {
        let env = try Layout.load("jlreq").environment(ofLink: 3)
        #expect(env.first.hasPrefix("定義 1.4"))
        #expect(env.last.hasPrefix("これらが結合律と単位律"))
    }

    @Test func termInsideADefinitionFindsTheWholeDefinition() throws {
        let layout = try Layout.load("jlreq")
        let pieces = layout.pieces(onPage: 0)
        // "普遍元" on the second line of 定義 1.3.
        let line = try #require(pieces.first { $0.text.hasPrefix("は F の普遍元") })
        let extent = try #require(EnvironmentExtent.enclosing(CGPoint(x: line.rect.midX, y: line.rect.midY), in: pieces)).rect
        let inside = pieces.filter { extent.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) }
        #expect(inside.contains { $0.text.hasPrefix("定義 1.3") })
        #expect(inside.contains { $0.text.hasPrefix("u が普遍元であるとき") })
        #expect(!inside.contains { $0.text.hasPrefix("定義 1.4") })
    }

    @Test func termInRunningTextHasNoEnclosingEnvironment() throws {
        let pieces = try Layout.load("jlreq").pieces(onPage: 0)
        let line = try #require(pieces.first { $0.text.hasPrefix("本文の段落") })
        #expect(EnvironmentExtent.enclosing(CGPoint(x: line.rect.midX, y: line.rect.midY), in: pieces) == nil)
    }

    // pagebreak.tex: 定義 1.1 starts at the bottom of page 1 and ends at the top of page 2;
    // 定義 1.2 follows it there.

    @Test func definitionRunningOffThePageContinues() throws {
        let layout = try Layout.load("pagebreak")
        let env = try layout.environment(ofLink: 0)
        #expect(env.first.hasPrefix("定義 1.1"))
        #expect(env.last.hasPrefix("•各対象の組"))
        let link = layout.links[0]
        let block = try #require(EnvironmentExtent.extent(of: layout.pieces(onPage: link.page), anchor: CGPoint(x: link.anchor[0], y: link.anchor[1])))
        #expect(block.continues)
    }

    @Test func continuationIsTheTopOfTheNextPage() throws {
        let layout = try Layout.load("pagebreak")
        let pieces = layout.pieces(onPage: 2)
        let block = try #require(EnvironmentExtent.continuation(on: pieces, after: layout.pieces(onPage: 1)))
        let inside = pieces.filter { block.rect.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) }
        #expect(inside.map(\.text) == ["これらが結合律と単位律を満たすとき C を圏という. □"])
        #expect(!block.continues)
    }

    @Test func definitionEndingOnItsPageDoesNotContinue() throws {
        let layout = try Layout.load("pagebreak")
        let link = layout.links[1]
        let block = try #require(EnvironmentExtent.extent(of: layout.pieces(onPage: link.page), anchor: CGPoint(x: link.anchor[0], y: link.anchor[1])))
        #expect(!block.continues)
    }

    @Test func pageStartingWithAHeadingContinuesNothing() throws {
        let pieces = try Layout.load("jlreq").pieces(onPage: 0).filter { $0.rect.minY > 270 }
        #expect(EnvironmentExtent.continuation(on: pieces, after: []) == nil)
    }

    @Test func continuationThroughADiagramOfSmallLabels() throws {
        // A commutative diagram at the top of the next page: many small centered labels, which
        // mustn't make the ordinary text line above them look like a large heading.
        let layout = try Layout.load("pagebreak")
        let first = try #require(layout.pieces(onPage: 2).first)
        let text = TextPiece(rect: CGRect(x: first.rect.minX, y: first.rect.minY, width: 300, height: first.rect.height),
                             text: "換 α: LanK(F) ⇒ G で γ = (αK)◦η を満たすものがただ 1 つ存在する.")
        let labels = (0..<12).map { i in
            TextPiece(rect: CGRect(x: 220 + CGFloat(i % 4) * 40, y: text.rect.maxY + 12 + CGFloat(i / 4) * 12, width: 12, height: 6.2), text: "F")
        }
        let end = TextPiece(rect: CGRect(x: first.rect.maxX - 8, y: text.rect.maxY + 60, width: 8, height: 11.5), text: "□")
        let block = try #require(EnvironmentExtent.continuation(on: [text] + labels + [end], after: layout.pieces(onPage: 1)))
        #expect(block.rect.minY <= text.rect.minY)
        #expect(block.rect.maxY >= end.rect.maxY)
    }

    @Test func titlePageFurtherDownContinuesNothing() throws {
        // Text starting a third of the way down (a colophon's title), after a page starting at the top.
        let layout = try Layout.load("pagebreak")
        let lowered = layout.pieces(onPage: 2).map { TextPiece(rect: $0.rect.offsetBy(dx: 0, dy: 250), text: $0.text) }
        #expect(EnvironmentExtent.continuation(on: lowered, after: layout.pieces(onPage: 1)) == nil)
    }

    @Test func termInTheCarriedOverPartFindsItsStart() throws {
        let layout = try Layout.load("pagebreak")
        let top = layout.pieces(onPage: 2)
        let line = try #require(top.first { $0.text.hasPrefix("これらが結合律") })
        let previous = layout.pieces(onPage: 1)
        #expect(EnvironmentExtent.isCarriedOver(CGPoint(x: line.rect.midX, y: line.rect.midY), in: top, after: previous))
        let following = try #require(top.first { $0.text.hasPrefix("定義 1.2") })
        #expect(!EnvironmentExtent.isCarriedOver(CGPoint(x: following.rect.midX, y: following.rect.midY), in: top, after: previous))

        let start = try #require(EnvironmentExtent.unfinished(on: previous))
        let inside = previous.filter { start.rect.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) }
        #expect(inside.contains { $0.text.hasPrefix("定義 1.1") })
        #expect(start.continues)
    }

    @Test func paddingStopsHalfwayToNeighbouringLines() {
        let above = TextPiece(rect: CGRect(x: 78, y: 100, width: 400, height: 14), text: "の前の行.")
        let body = TextPiece(rect: CGRect(x: 78, y: 116, width: 400, height: 14), text: "定義 2.5 本文.")
        let below = TextPiece(rect: CGRect(x: 78, y: 160, width: 400, height: 14), text: "次の段落.")
        let padded = EnvironmentExtent.padded(body.rect, among: [above, body, below])
        #expect(padded.minY == 115)  // halfway across the 2pt gap, not 6pt into the line above
        #expect(padded.maxY == 136)  // the full margin: the next line is far
        #expect(padded.minX == 70 && padded.width == 416)
    }

    @Test func maxHeightCapsTheExtent() {
        let pieces = (0..<40).map { TextPiece(rect: CGRect(x: 72, y: 100 + CGFloat($0) * 12, width: 400, height: 9), text: "line \($0)") }
        let extent = EnvironmentExtent.extent(of: pieces, anchor: CGPoint(x: 72, y: 98), maxHeight: 100)
        #expect(extent?.rect.height == 100)
    }
}
