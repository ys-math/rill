import Foundation

/// A value from rill's TOML subset.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    /// Integers and floats both read as a number.
    public var number: Double? {
        switch self {
        case .integer(let i): Double(i)
        case .float(let f): f
        default: nil
        }
    }

    public var typeName: String {
        switch self {
        case .string: "string"
        case .integer: "integer"
        case .float: "float"
        case .bool: "boolean"
        case .array: "array"
        }
    }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String

    public var description: String { "line \(line): \(message)" }
}

/// Parses the subset of TOML rill's config uses: `[table]` headers, `key = value` with bare or
/// quoted keys, basic ("…", with escapes) and literal ('…') strings, integers, floats, booleans,
/// arrays (which may span lines), and `#` comments. Not supported: inline tables, arrays of
/// tables, dotted keys, dates, multi-line strings.
public enum TOML {
    /// Table name → key → value. Keys before any header are in the "" table.
    public typealias Document = [String: [String: TOMLValue]]

    public static func parse(_ text: String) throws(TOMLError) -> Document {
        var document: Document = ["": [:]]
        var table = ""
        var lines = text.components(separatedBy: .newlines)[...]
        var lineNumber = 0

        while let raw = lines.popFirst() {
            lineNumber += 1
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("[") {
                guard !line.hasPrefix("[[") else { throw TOMLError(line: lineNumber, message: "arrays of tables are not supported") }
                var scanner = Scanner(line.dropFirst(), line: lineNumber)
                let name = try scanner.key()
                scanner.skipSpaces()
                guard scanner.consume("]") else { throw TOMLError(line: lineNumber, message: "expected ] after table name") }
                try scanner.expectEnd()
                guard document[name] == nil || name.isEmpty else {
                    throw TOMLError(line: lineNumber, message: "table [\(name)] defined twice")
                }
                table = name
                if document[name] == nil { document[name] = [:] }
                continue
            }

            // An array value may continue over several lines; gather until brackets balance.
            let startLine = lineNumber
            while Scanner.openBrackets(in: line) > 0, let next = lines.popFirst() {
                lineNumber += 1
                line += "\n" + next
            }
            var scanner = Scanner(Substring(line), line: startLine)
            let key = try scanner.key()
            scanner.skipSpaces()
            guard scanner.consume("=") else { throw TOMLError(line: startLine, message: "expected = after \(key)") }
            scanner.skipSpaces()
            let value = try scanner.value()
            try scanner.expectEnd()
            guard document[table]?[key] == nil else {
                throw TOMLError(line: startLine, message: "\(key) is set twice")
            }
            document[table, default: [:]][key] = value
        }
        return document
    }

    private struct Scanner {
        var rest: Substring
        let line: Int

        init(_ text: Substring, line: Int) {
            self.rest = text
            self.line = line
        }

        func error(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

        mutating func skipSpaces(newlines: Bool = false) {
            while let c = rest.first {
                if c == " " || c == "\t" || (newlines && c == "\n") {
                    rest.removeFirst()
                } else if newlines, c == "#" {
                    // A comment inside a multi-line array runs to the end of its line.
                    while let d = rest.first, d != "\n" { rest.removeFirst() }
                } else {
                    return
                }
            }
        }

        mutating func consume(_ c: Character) -> Bool {
            guard rest.first == c else { return false }
            rest.removeFirst()
            return true
        }

        mutating func expectEnd() throws(TOMLError) {
            skipSpaces()
            guard rest.isEmpty || rest.first == "#" else { throw error("unexpected \(rest.prefix(20))") }
        }

        mutating func key() throws(TOMLError) -> String {
            skipSpaces()
            switch rest.first {
            case "\"": return try basicString()
            case "'": return try literalString()
            default:
                let bare = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                guard !bare.isEmpty else { throw error("expected a key") }
                rest.removeFirst(bare.count)
                return String(bare)
            }
        }

        mutating func value() throws(TOMLError) -> TOMLValue {
            switch rest.first {
            case "\"": return .string(try basicString())
            case "'": return .string(try literalString())
            case "[": return try array()
            case "{": throw error("inline tables are not supported")
            case nil: throw error("missing value")
            default: return try scalar()
            }
        }

        mutating func array() throws(TOMLError) -> TOMLValue {
            rest.removeFirst() // [
            var items: [TOMLValue] = []
            while true {
                skipSpaces(newlines: true)
                if consume("]") { return .array(items) }
                items.append(try value())
                skipSpaces(newlines: true)
                if consume(",") { continue }
                guard consume("]") else { throw error("expected , or ] in array") }
                return .array(items)
            }
        }

        mutating func scalar() throws(TOMLError) -> TOMLValue {
            let token = rest.prefix { !" \t\n,]#".contains($0) }
            rest.removeFirst(token.count)
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
            let digits = token.replacingOccurrences(of: "_", with: "")
            if let i = Int(digits) { return .integer(i) }
            if let f = Double(digits), digits.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) { return .float(f) }
            throw error("unrecognized value \(token.isEmpty ? "(empty)" : String(token)); strings need quotes")
        }

        mutating func literalString() throws(TOMLError) -> String {
            rest.removeFirst() // '
            guard let end = rest.firstIndex(of: "'"), !rest[..<end].contains("\n") else { throw error("unterminated string") }
            let s = String(rest[..<end])
            rest = rest[rest.index(after: end)...]
            return s
        }

        mutating func basicString() throws(TOMLError) -> String {
            rest.removeFirst() // "
            var result = ""
            while let c = rest.popFirst() {
                switch c {
                case "\"": return result
                case "\n": throw error("unterminated string")
                case "\\":
                    guard let e = rest.popFirst() else { throw error("unterminated string") }
                    switch e {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "u", "U":
                        let count = e == "u" ? 4 : 8
                        let hex = rest.prefix(count)
                        guard hex.count == count, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                            throw error("bad unicode escape")
                        }
                        rest.removeFirst(count)
                        result.unicodeScalars.append(scalar)
                    default: throw error("unknown escape \\\(e)")
                    }
                default:
                    result.append(c)
                }
            }
            throw error("unterminated string")
        }

        /// Unclosed `[` outside strings and comments, for gathering multi-line arrays.
        static func openBrackets(in text: String) -> Int {
            var depth = 0
            var quote: Character?
            var escaped = false
            var sawEquals = false
            var inComment = false
            for c in text {
                if inComment {
                    if c == "\n" { inComment = false }
                    continue
                }
                if let q = quote {
                    if escaped { escaped = false } else if c == "\\" && q == "\"" { escaped = true } else if c == q { quote = nil }
                    continue
                }
                switch c {
                case "\"", "'": quote = c
                case "#": inComment = true
                case "=": sawEquals = true
                case "[" where sawEquals: depth += 1
                case "]" where sawEquals: depth -= 1
                default: break
                }
            }
            return depth
        }
    }
}
