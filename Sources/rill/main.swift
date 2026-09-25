import AppKit
import RillCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("rill: \(message)\n".utf8))
    exit(code)
}

func absolutePath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}

func installedApp() -> URL {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Rill.bundleIdentifier) else {
        fail("Rill.app is not installed (run `make install`)")
    }
    return app
}

/// Sends a request to the running app, launching it in the background first if needed.
func send(_ request: IPCRequest) async -> IPCResponse {
    let socket = IPC.socketURL.path
    let line: Data
    do { line = try IPC.encodeLine(request) } catch { fail("could not encode request: \(error)") }

    func attempt() throws(SocketError) -> IPCResponse {
        let data = try UnixSocket.request(path: socket, line: line)
        guard let response = try? IPC.decodeLine(IPCResponse.self, from: data) else {
            return .failure("unreadable response from rill")
        }
        return response
    }

    do {
        return try attempt()
    } catch where error.isNotListening {
        // Not running: launch without stealing focus, then wait for the socket to come up.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = request.activate
        _ = try? await NSWorkspace.shared.openApplication(at: installedApp(), configuration: configuration)
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(50))
            do { return try attempt() } catch where error.isNotListening { continue } catch { return .failure("\(error)") }
        }
        return .failure("rill did not start listening on \(socket)")
    } catch {
        return .failure("\(error)")
    }
}

let command: CLICommand
do {
    command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\(CLICommand.usage)", code: 64)
}

switch command {
case .help:
    print(CLICommand.usage)

case .version:
    print("rill \(Rill.version)")

case .open(let pdf):
    let url = URL(fileURLWithPath: absolutePath(pdf))
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(url.path)") }
    do {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: installedApp(), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    } catch {
        fail("could not open \(url.path): \(error.localizedDescription)")
    }

case .forward(let location, let pdf, let activate):
    let pdfPath = absolutePath(pdf)
    guard FileManager.default.fileExists(atPath: pdfPath) else { fail("no such file: \(pdfPath)") }
    var source = location
    source.file = absolutePath(location.file)
    let response = await send(IPCRequest(command: .forward, pdf: pdfPath, source: source, activate: activate))
    if !response.ok { fail(response.error ?? "forward search failed") }
}
