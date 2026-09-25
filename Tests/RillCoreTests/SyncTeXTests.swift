import CoreGraphics
import Foundation
import Testing
@testable import RillCore

/// Fixtures/fixture.tex compiled with `pdflatex -synctex=1`:
///
///     3  First paragraph on page one.
///     5  \newpage
///     6  Second page text here.
///     8  Another line on page two.
///     9  \section{A section}
///    10  (a paragraph on one source line that wraps onto four lines)
struct SyncTeXTests {
    let pdf = Bundle.module.url(forResource: "fixture", withExtension: "pdf", subdirectory: "Fixtures")!.path
    /// SyncTeX records the absolute path at compile time; queries match on path suffixes,
    /// so a path from anywhere else must still resolve.
    let tex = "/somewhere/else/fixture.tex"

    @Test func missingDataIsNil() {
        #expect(SyncTeX(pdfPath: "/nonexistent/x.pdf") == nil)
    }

    @Test func forwardFindsTheRightPage() throws {
        let sync = try #require(SyncTeX(pdfPath: pdf))
        let first = sync.boxes(for: SourceLocation(line: 3, column: 0, file: tex))
        let second = sync.boxes(for: SourceLocation(line: 8, column: 0, file: tex))
        #expect(first.first?.page == 0)
        #expect(second.first?.page == 1)
        #expect(!first.isEmpty && first.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
    }

    @Test func linesOnTheSamePageAreOrderedTopToBottom() throws {
        let sync = try #require(SyncTeX(pdfPath: pdf))
        let upper = try #require(sync.boxes(for: SourceLocation(line: 6, column: 0, file: tex)).first)
        let lower = try #require(sync.boxes(for: SourceLocation(line: 8, column: 0, file: tex)).first)
        #expect(upper.page == lower.page)
        #expect(upper.rect.minY < lower.rect.minY)
    }

    @Test func keepsOnlyTheBestMatchingTextLine() throws {
        let sync = try #require(SyncTeX(pdfPath: pdf))
        for line in [9, 10] {
            let boxes = sync.boxes(for: SourceLocation(line: line, column: 0, file: tex))
            let first = try #require(boxes.first)
            let band = boxes.map(\.rect).reduce(first.rect) { $0.union($1) }
            // One text line (~10 pt at 10pt type), not the four lines the paragraph wraps onto.
            #expect(band.height < first.rect.height * 1.5)
        }
    }

    @Test func inverseRoundTrips() throws {
        let sync = try #require(SyncTeX(pdfPath: pdf))
        for line in [3, 6, 8] {
            let box = try #require(sync.boxes(for: SourceLocation(line: line, column: 0, file: tex)).first)
            let location = try #require(sync.location(page: box.page, x: box.rect.midX, y: box.rect.midY))
            #expect(location.line == line)
            #expect(location.file.hasSuffix("/fixture.tex"))
            #expect(!location.file.contains("/./"))
        }
    }
}
