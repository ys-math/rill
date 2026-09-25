import Foundation
import Testing
@testable import RillCore

struct IPCTests {
    @Test func requestRoundTripsAsOneLine() throws {
        let request = IPCRequest(command: .forward, pdf: "/p/main.pdf",
                                 source: SourceLocation(line: 42, column: 3, file: "/p/main.tex"), activate: true)
        let line = try IPC.encodeLine(request)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(try IPC.decodeLine(IPCRequest.self, from: line) == request)
    }

    @Test func responseRoundTrips() throws {
        let line = try IPC.encodeLine(IPCResponse.failure("no SyncTeX data"))
        #expect(try IPC.decodeLine(IPCResponse.self, from: line) == .failure("no SyncTeX data"))
    }

    @Test func ignoresTrailingData() throws {
        var data = try IPC.encodeLine(IPCResponse.success)
        data.append(contentsOf: Array("garbage".utf8))
        #expect(try IPC.decodeLine(IPCResponse.self, from: data) == .success)
    }
}

struct InverseSearchCommandTests {
    @Test func rendersVimtexDefault() throws {
        let command = try InverseSearchCommand.vimtexDefault.render(SourceLocation(line: 12, column: 0, file: "/Users/me/My Paper/main.tex"))
        #expect(command == #"nvim --headless -c "VimtexInverseSearch 12 '/Users/me/My Paper/main.tex'""#)
    }

    @Test func rendersAllPlaceholders() throws {
        let command = try InverseSearchCommand(template: "open-at %file:%line:%column")
            .render(SourceLocation(line: 7, column: 4, file: "/a.tex"))
        #expect(command == "open-at /a.tex:7:4")
    }

    @Test func refusesPathsThatBreakQuoting() {
        for path in ["/it's.tex", "/a\"b.tex", "/$HOME.tex", "/a`b`.tex", "/a\\b.tex"] {
            #expect(throws: InverseSearchCommand.Failure.unsafePath(path)) {
                try InverseSearchCommand.vimtexDefault.render(SourceLocation(line: 1, column: 0, file: path))
            }
        }
    }
}
