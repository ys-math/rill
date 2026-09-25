/// A source location handed to rill by vimtex for forward search (`@line:@col:@tex`).
public struct SourceLocation: Equatable, Sendable {
    public var line: Int
    public var column: Int
    public var file: String

    public init(line: Int, column: Int, file: String) {
        self.line = line
        self.column = column
        self.file = file
    }
}

/// What the `rill` CLI was asked to do.
public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case open(pdf: String)
    case forward(SourceLocation, pdf: String)
}

public enum CLIParseError: Error, Equatable, CustomStringConvertible {
    case missingPDF
    case missingForwardLocation
    case invalidForwardLocation(String)
    case unknownOption(String)
    case unexpectedArgument(String)

    public var description: String {
        switch self {
        case .missingPDF: "no PDF file given"
        case .missingForwardLocation: "--forward needs LINE:COL:TEX"
        case .invalidForwardLocation(let s): "invalid forward location '\(s)', expected LINE:COL:TEX"
        case .unknownOption(let s): "unknown option '\(s)'"
        case .unexpectedArgument(let s): "unexpected argument '\(s)'"
        }
    }
}

extension CLICommand {
    public static let usage = """
        usage: rill FILE.pdf
               rill --forward LINE:COL:TEX FILE.pdf
               rill --version | --help
        """

    /// Parses arguments, excluding the program name.
    public static func parse(_ args: [String]) throws(CLIParseError) -> CLICommand {
        var args = args[...]
        guard let first = args.popFirst() else { return .help }

        switch first {
        case "-h", "--help":
            return .help
        case "-v", "--version":
            return .version
        case "--forward":
            guard let spec = args.popFirst() else { throw .missingForwardLocation }
            let location = try parseLocation(spec)
            guard let pdf = args.popFirst() else { throw .missingPDF }
            if let extra = args.first { throw .unexpectedArgument(extra) }
            return .forward(location, pdf: pdf)
        case let option where option.hasPrefix("-"):
            throw .unknownOption(option)
        default:
            if let extra = args.first { throw .unexpectedArgument(extra) }
            return .open(pdf: first)
        }
    }

    /// `LINE:COL:TEX`. The TEX path may itself contain colons, so only the first two are separators.
    /// vimtex may pass an empty or negative column; that is treated as column 0.
    private static func parseLocation(_ spec: String) throws(CLIParseError) -> SourceLocation {
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let line = Int(parts[0]), line > 0,
              !parts[2].isEmpty
        else { throw .invalidForwardLocation(spec) }
        let column = max(Int(parts[1]) ?? 0, 0)
        return SourceLocation(line: line, column: column, file: String(parts[2]))
    }
}
