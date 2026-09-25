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
                                pdf: "/Users/me/paper/main.pdf", activate: false))
    }

    @Test func forwardTexPathMayContainColons() throws {
        let cmd = try CLICommand.parse(["--forward", "3:1:/tmp/a:b.tex", "a.pdf"])
        #expect(cmd == .forward(SourceLocation(line: 3, column: 1, file: "/tmp/a:b.tex"), pdf: "a.pdf", activate: false))
    }

    @Test func forwardToleratesMissingColumn() throws {
        let empty = try CLICommand.parse(["--forward", "3::main.tex", "a.pdf"])
        #expect(empty == .forward(SourceLocation(line: 3, column: 0, file: "main.tex"), pdf: "a.pdf", activate: false))
        let negative = try CLICommand.parse(["--forward", "3:-1:main.tex", "a.pdf"])
        #expect(negative == .forward(SourceLocation(line: 3, column: 0, file: "main.tex"), pdf: "a.pdf", activate: false))
    }

    @Test func activateFlagAnywhere() throws {
        let location = SourceLocation(line: 1, column: 0, file: "a.tex")
        #expect(try CLICommand.parse(["--activate", "--forward", "1:0:a.tex", "a.pdf"]) == .forward(location, pdf: "a.pdf", activate: true))
        #expect(try CLICommand.parse(["--forward", "1:0:a.tex", "a.pdf", "--activate"]) == .forward(location, pdf: "a.pdf", activate: true))
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
