import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible, Equatable {
    public let operation: String
    public let code: Int32

    public init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    /// Nobody is listening (app not running, or a stale socket file).
    public var isNotListening: Bool { code == ENOENT || code == ECONNREFUSED }

    public var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// Minimal line-oriented Unix domain sockets: one request line in, one response line out.
public enum UnixSocket {
    /// Connects, sends `line`, and returns everything read up to the first newline (or EOF).
    public static func request(path: String, line: Data, timeout: TimeInterval = 5) throws(SocketError) -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        defer { close(fd) }
        setTimeout(fd, timeout)
        var address = try makeAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw SocketError("connect") }
        try writeAll(fd, line)
        return try readLine(fd)
    }

    static func makeAddress(_ path: String) throws(SocketError) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError("path too long", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws(SocketError) {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            guard written > 0 else { throw SocketError("write") }
            offset += written
        }
    }

    /// Reads until a newline or EOF. Lines are capped at 1 MB.
    static func readLine(_ fd: Int32) throws(SocketError) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !result.contains(0x0A), result.count < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw SocketError("read") }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }
}

/// Listens on a Unix domain socket. Each connection's request line is handed to `handler`
/// on `queue`; calling the supplied reply closure sends the response and closes the connection.
public final class UnixSocketServer: @unchecked Sendable { // `listener` is only touched on `ioQueue`
    public typealias Handler = (_ request: Data, _ reply: @escaping @Sendable (Data) -> Void) -> Void

    public let path: String
    private let fd: Int32
    private let ioQueue = DispatchQueue(label: "rill.socket")
    private var listener: DispatchSourceRead?

    public init(path: String, queue: DispatchQueue, handler: @escaping Handler) throws(SocketError) {
        self.path = path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        // A leftover socket file from a crashed run would make bind fail.
        unlink(path)
        var address = try UnixSocket.makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = SocketError("bind"); close(fd); throw e }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = SocketError("listen"); close(fd); throw e }
        self.fd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [ioQueue] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            UnixSocket.setTimeout(client, 2)
            ioQueue.async {
                guard let request = try? UnixSocket.readLine(client), !request.isEmpty else { close(client); return }
                let reply: @Sendable (Data) -> Void = { response in
                    try? UnixSocket.writeAll(client, response)
                    close(client)
                }
                queue.async { handler(request, reply) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    public func stop() {
        ioQueue.sync {
            listener?.cancel()
            listener = nil
        }
        unlink(path)
    }

    deinit {
        listener?.cancel()
    }
}
