import Foundation

/// The CLI ↔ app protocol: one JSON object per line over a Unix domain socket.
/// Each connection carries one request and one response.
public enum IPC {
    /// `~/Library/Application Support/rill/rill.sock`
    public static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rill/rill.sock")
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let line = data.split(separator: 0x0A, omittingEmptySubsequences: true).first ?? Data()
        return try JSONDecoder().decode(type, from: Data(line))
    }
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public enum Command: String, Codable, Sendable {
        case open
        case forward
    }

    public var command: Command
    /// Absolute path of the PDF.
    public var pdf: String
    /// Forward search: the source location.
    public var source: SourceLocation?
    /// Bring rill to the front afterwards.
    public var activate: Bool

    public init(command: Command, pdf: String, source: SourceLocation? = nil, activate: Bool = false) {
        self.command = command
        self.pdf = pdf
        self.source = source
        self.activate = activate
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }

    public static let success = IPCResponse(ok: true)
    public static func failure(_ message: String) -> IPCResponse { IPCResponse(ok: false, error: message) }
}

/// The shell command run for inverse search, e.g.
/// `nvim --headless -c "VimtexInverseSearch %line '%file'"`.
public struct InverseSearchCommand: Equatable, Sendable {
    public static let vimtexDefault = InverseSearchCommand(template: #"nvim --headless -c "VimtexInverseSearch %line '%file'""#)

    public var template: String

    public init(template: String) {
        self.template = template
    }

    public enum Failure: Error, Equatable {
        /// The path has a character that can't be substituted safely into a quoted shell word.
        case unsafePath(String)
    }

    /// Characters that would end or reinterpret the quoted strings the template puts `%file` in.
    static let unsafeCharacters = CharacterSet(charactersIn: "\"'`$\\\n")

    public func render(_ location: SourceLocation) throws(Failure) -> String {
        guard location.file.rangeOfCharacter(from: Self.unsafeCharacters) == nil else {
            throw .unsafePath(location.file)
        }
        return template
            .replacingOccurrences(of: "%line", with: String(location.line))
            .replacingOccurrences(of: "%column", with: String(location.column))
            .replacingOccurrences(of: "%file", with: location.file)
    }
}
