import CoreGraphics
import Foundation
import Testing
@testable import RillCore

struct PDFCompletenessTests {
    let body = "%PDF-1.5\n1 0 obj << >> endobj\ntrailer << >>\nstartxref\n0\n"

    @Test func completeFile() {
        #expect(PDFCompleteness.looksComplete(Data((body + "%%EOF").utf8)))
        #expect(PDFCompleteness.looksComplete(Data((body + "%%EOF\n").utf8)))
        #expect(PDFCompleteness.looksComplete(Data((body + "%%EOF\r\n  ").utf8)))
    }

    @Test func truncatedFile() {
        #expect(!PDFCompleteness.looksComplete(Data(body.utf8)))
        #expect(!PDFCompleteness.looksComplete(Data((body + "%%EO").utf8)))
        #expect(!PDFCompleteness.looksComplete(Data()))
    }

    @Test func incrementalUpdateInProgress() {
        // An earlier %%EOF followed by more objects: still being written.
        #expect(!PDFCompleteness.looksComplete(Data((body + "%%EOF\n2 0 obj << >> endobj\n").utf8)))
    }

    @Test func notAPDF() {
        #expect(!PDFCompleteness.looksComplete(Data("hello %%EOF".utf8)))
    }
}

struct PagePositionTests {
    let layout = PageLayout(pageSizes: [CGSize(width: 600, height: 800), CGSize(width: 600, height: 800)], gap: 10, margin: 20)

    @Test func roundTrips() {
        for y: CGFloat in [20, 420, 815, 830, 1000] {
            #expect(abs(layout.y(for: layout.position(atY: y)) - y) < 0.001)
        }
    }

    @Test func positionIsRelativeToPage() {
        #expect(layout.position(atY: 830 + 400) == PagePosition(page: 1, offset: 0.5))
    }

    @Test func survivesPagesGrowing() {
        // The same spot on page 2 after page 1 got taller.
        let position = layout.position(atY: 830 + 400)
        let grown = PageLayout(pageSizes: [CGSize(width: 600, height: 900), CGSize(width: 600, height: 800)], gap: 10, margin: 20)
        #expect(abs(grown.y(for: position) - (930 + 400)) < 0.001)
    }

    @Test func clampsWhenPagesDisappear() {
        let shorter = PageLayout(pageSizes: [CGSize(width: 600, height: 800)], gap: 10, margin: 20)
        #expect(shorter.y(for: PagePosition(page: 5, offset: 0.5)) == 15)
    }
}

struct DocumentStateStoreTests {
    func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rill-tests-\(UUID().uuidString)/documents.json")
    }

    @Test func persistsAcrossInstances() throws {
        let url = temporaryURL()
        let store = DocumentStateStore(fileURL: url)
        let state = DocumentState(position: PagePosition(page: 3, offset: 0.25), x: 12, zoom: .magnification(1.5))
        store.set(state, forPath: "/a.pdf")
        try store.save()

        let reloaded = DocumentStateStore(fileURL: url)
        #expect(reloaded.state(forPath: "/a.pdf")?.position == state.position)
        #expect(reloaded.state(forPath: "/a.pdf")?.zoom == .magnification(1.5))
        #expect(reloaded.state(forPath: "/b.pdf") == nil)
    }

    @Test func evictsOldestBeyondCapacity() {
        let store = DocumentStateStore(fileURL: temporaryURL(), capacity: 2)
        for (i, path) in ["/1.pdf", "/2.pdf", "/3.pdf"].enumerated() {
            store.set(DocumentState(position: PagePosition(page: 0, offset: 0), zoom: .fitWidth,
                                    lastOpened: Date(timeIntervalSince1970: Double(i))), forPath: path)
        }
        #expect(store.recentPaths() == ["/3.pdf", "/2.pdf"])
    }

    @Test func missingOrCorruptFileStartsEmpty() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(DocumentStateStore(fileURL: url).recentPaths().isEmpty)
    }
}
