import AppKit
import RillCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("rill: \(message)\n".utf8))
    exit(code)
}

func absoluteURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
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
    let url = absoluteURL(pdf)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(url.path)") }
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Rill.bundleIdentifier) else {
        fail("Rill.app is not installed (run `make install`)")
    }
    do {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    } catch {
        fail("could not open \(url.path): \(error.localizedDescription)")
    }

case .forward:
    // Forward search over the app socket arrives in milestone 4.
    fail("--forward is not implemented yet", code: 2)
}
