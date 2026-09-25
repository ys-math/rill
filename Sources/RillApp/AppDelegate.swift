import AppKit
import RillCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = DocumentStateStore(
        fileURL: ProcessInfo.processInfo.environment["RILL_STATE_FILE"].map { URL(fileURLWithPath: $0) } ?? DocumentStateStore.defaultURL)
    private var windows: [DocumentWindowController] = []
    private var openedAnyDocument = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        // Files passed at launch arrive via application(_:open:) before this returns control
        // to the run loop, so defer the empty-window check by one turn.
        DispatchQueue.main.async { [self] in
            if !openedAnyDocument { show(DocumentWindowController(url: nil, store: store)) }
            NSApp.activate()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedAnyDocument = true
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            if let existing = windows.first(where: { $0.url == url }) {
                existing.showWindow(nil)
            } else if let empty = windows.first(where: { $0.url == nil }) {
                empty.load(url)
            } else {
                show(DocumentWindowController(url: url, store: store))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for window in windows { window.saveState() }
        try? store.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func show(_ controller: DocumentWindowController) {
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
    }
}
