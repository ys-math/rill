import Foundation
import Testing
@testable import RillCore

struct UnixSocketTests {
    /// Socket paths are limited to ~104 bytes, so use a short temporary one.
    func socketPath() -> String {
        "/tmp/rill-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func requestAndResponse() throws {
        let path = socketPath()
        let server = try UnixSocketServer(path: path, queue: DispatchQueue(label: "test")) { request, reply in
            let decoded = try! IPC.decodeLine(IPCRequest.self, from: request)
            reply(try! IPC.encodeLine(IPCResponse.failure("got \(decoded.pdf)")))
        }
        defer { server.stop() }

        let line = try IPC.encodeLine(IPCRequest(command: .open, pdf: "/x.pdf"))
        let response = try UnixSocket.request(path: path, line: line)
        #expect(try IPC.decodeLine(IPCResponse.self, from: response) == .failure("got /x.pdf"))
    }

    @Test func handlesSeveralConnections() throws {
        let path = socketPath()
        let server = try UnixSocketServer(path: path, queue: DispatchQueue(label: "test")) { request, reply in
            reply(request)
        }
        defer { server.stop() }
        for i in 0..<5 {
            let response = try UnixSocket.request(path: path, line: Data("ping \(i)\n".utf8))
            #expect(response == Data("ping \(i)\n".utf8))
        }
    }

    @Test func reportsNobodyListening() {
        do {
            _ = try UnixSocket.request(path: socketPath(), line: Data("x\n".utf8))
            Issue.record("expected a connection failure")
        } catch {
            #expect(error.isNotListening)
        }
    }

    @Test func replacesStaleSocketFile() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = try UnixSocketServer(path: path, queue: DispatchQueue(label: "test")) { request, reply in reply(request) }
        defer { server.stop() }
        #expect(try UnixSocket.request(path: path, line: Data("ok\n".utf8)) == Data("ok\n".utf8))
    }
}
