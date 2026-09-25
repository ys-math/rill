import Testing
@testable import RillCore

struct CLICommandTests {
    @Test func noArgumentsShowsHelp() throws {
        #expect(try CLICommand.parse([]) == .help)
    }

    @Test func versionAndHelpFlags() throws {
        #expect(try CLICommand.parse(["--version"]) == .version)
        #expect(try CLICommand.parse(["-v"]) == .version)
        #expect(try CLICommand.parse(["--help"]) == .help)
    }

    @Test func opensAPDF() throws {
        #expect(try CLICommand.parse(["thesis.pdf"]) == .open(pdf: "thesis.pdf"))
    }

    @Test func parsesVimtexForwardSearch() throws {
        let cmd = try CLICommand.parse(["--forward", "42:7:/Users/me/paper/main.tex", "/Users/me/paper/main.pdf"])
        #expect(cmd == .forward(SourceLocation(line: 42, column: 7, file: "/Users/me/paper/main.tex"),
                                pdf: "/Users/me/paper/main.pdf"))
    }

    @Test func forwardTexPathMayContainColons() throws {
        let cmd = try CLICommand.parse(["--forward", "3:1:/tmp/a:b.tex", "a.pdf"])
        #expect(cmd == .forward(SourceLocation(line: 3, column: 1, file: "/tmp/a:b.tex"), pdf: "a.pdf"))
    }

    @Test func forwardToleratesMissingColumn() throws {
        let empty = try CLICommand.parse(["--forward", "3::main.tex", "a.pdf"])
        #expect(empty == .forward(SourceLocation(line: 3, column: 0, file: "main.tex"), pdf: "a.pdf"))
        let negative = try CLICommand.parse(["--forward", "3:-1:main.tex", "a.pdf"])
        #expect(negative == .forward(SourceLocation(line: 3, column: 0, file: "main.tex"), pdf: "a.pdf"))
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: CLIParseError.missingForwardLocation) { try CLICommand.parse(["--forward"]) }
        #expect(throws: CLIParseError.missingPDF) { try CLICommand.parse(["--forward", "1:1:a.tex"]) }
        #expect(throws: CLIParseError.invalidForwardLocation("x:1:a.tex")) {
            try CLICommand.parse(["--forward", "x:1:a.tex", "a.pdf"])
        }
        #expect(throws: CLIParseError.invalidForwardLocation("0:1:a.tex")) {
            try CLICommand.parse(["--forward", "0:1:a.tex", "a.pdf"])
        }
        #expect(throws: CLIParseError.unknownOption("--bogus")) { try CLICommand.parse(["--bogus"]) }
        #expect(throws: CLIParseError.unexpectedArgument("b.pdf")) { try CLICommand.parse(["a.pdf", "b.pdf"]) }
    }
}
