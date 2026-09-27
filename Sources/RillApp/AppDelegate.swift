import AppKit
import RillCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = DocumentStateStore(
        fileURL: ProcessInfo.processInfo.environment["RILL_STATE_FILE"].map { URL(fileURLWithPath: $0) } ?? DocumentStateStore.defaultURL)
    private var windows: [DocumentWindowController] = []
    private var server: UnixSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        ConfigStore.shared.onProblem = { [weak self] message in self?.showProblem(message) }
        startServer()
    }

    /// Config problems go to the frontmost document; with none open, to the next one that opens.
    private var pendingProblem: String?

    private func showProblem(_ message: String) {
        if let front = windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first, front.showToast(message) {
            return
        }
        pendingProblem = message
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            window(for: url, activate: true)
        }
    }

    /// Dock icon clicked with nothing open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, windows.isEmpty { show(DocumentWindowController(url: nil, store: store)) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        for window in windows { window.saveState() }
        try? store.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Windows

    /// The window showing `url`, opening one if needed. Without `activate`, a new window is put
    /// on screen without taking focus from the editor, and an existing one is left where it is.
    @discardableResult
    private func window(for url: URL, activate: Bool) -> DocumentWindowController {
        let path = url.standardizedFileURL.path
        let controller: DocumentWindowController
        var isNew = false
        if let existing = windows.first(where: { $0.url?.standardizedFileURL.path == path }) {
            controller = existing
        } else if let empty = windows.first(where: { $0.url == nil }) {
            empty.load(url)
            controller = empty
        } else {
            controller = DocumentWindowController(url: url, store: store)
            windows.append(controller)
            controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
            isNew = true
        }
        if activate {
            NSApp.activate()
            controller.showWindow(nil)
        } else if isNew || controller.window?.isMiniaturized == true {
            controller.window?.orderFrontRegardless()
        }
        if let problem = pendingProblem, controller.showToast(problem) { pendingProblem = nil }
        return controller
    }

    private func show(_ controller: DocumentWindowController) {
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
        controller.showWindow(nil)
    }

    // MARK: - Socket

    private func startServer() {
        let path = IPC.socketURL.path
        try? FileManager.default.createDirectory(at: IPC.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            server = try UnixSocketServer(path: path, queue: .main) { [weak self] request, reply in
                MainActor.assumeIsolated { self?.handle(request, reply: reply) }
            }
        } catch {
            syncLog.error("could not listen on \(path, privacy: .public): \(error.description, privacy: .public)")
        }
    }

    private func handle(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        func respond(_ response: IPCResponse) {
            reply((try? IPC.encodeLine(response)) ?? Data("{\"ok\":false}\n".utf8))
        }
        guard let request = try? IPC.decodeLine(IPCRequest.self, from: data) else {
            return respond(.failure("malformed request"))
        }
        let url = URL(fileURLWithPath: request.pdf)
        guard FileManager.default.fileExists(atPath: url.path) else { return respond(.failure("no such file: \(url.path)")) }

        switch request.command {
        case .open:
            window(for: url, activate: request.activate)
            respond(.success)
        case .forward:
            guard let source = request.source else { return respond(.failure("forward search needs a source location")) }
            let controller = window(for: url, activate: request.activate || ConfigStore.shared.config.activateOnForward)
            Task {
                let error = await controller.forwardSearch(source)
                respond(error.map(IPCResponse.failure) ?? .success)
            }
        }
    }
}
