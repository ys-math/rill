import AppKit
import RillCore

/// One window per document, with no visible chrome. Owns the file watcher and the
/// document's remembered state.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    private(set) var url: URL?
    var onClose: (() -> Void)?

    private let store: DocumentStateStore
    private var documentController: DocumentViewController?
    private var reloader: DocumentReloader?
    private let placeholder = NSTextField(labelWithString: "")

    init(url: URL?, store: DocumentStateStore) {
        self.store = store
        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .preferred
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak self] in self?.documentController?.handleEscape() }

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        placeholder.alignment = .center
        load(url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL?) {
        saveState()
        reloader?.stop()
        reloader = nil
        self.url = url
        guard let window else { return }
        window.title = url?.lastPathComponent ?? "rill"
        window.representedURL = url

        guard let url else { return showPlaceholder("rill — no document") }
        do {
            let source = try PDFSource(url: url)
            let controller = DocumentViewController(source: source, state: store.state(forPath: url.path))
            documentController = controller
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 900, height: 1100))

            let reloader = DocumentReloader(url: url, current: source)
            reloader.onReload = { [weak controller] in controller?.replace(with: $0, noticed: $1) }
            controller.onReloadRequested = { [weak reloader] in reloader?.forceReload() }
            reloader.start()
            self.reloader = reloader

            DebugSnapshot.runIfRequested(window: window, document: controller)
        } catch {
            showPlaceholder("could not open \(url.lastPathComponent)\n\(error.localizedDescription)")
        }
    }

    /// Forward search in this window's document. Returns an error message, or nil on success.
    func forwardSearch(_ location: SourceLocation) async -> String? {
        guard let documentController else { return "could not open \(url?.lastPathComponent ?? "document")" }
        return await documentController.forwardSearch(location)
    }

    /// Shows a message in this window. Returns false if there's no document to show it in.
    @discardableResult
    func showToast(_ message: String) -> Bool {
        guard let documentController, documentController.isViewLoaded else { return false }
        documentController.showToast(message)
        return true
    }

    /// Records where the document is scrolled to. The store is written to disk by the app delegate.
    func saveState() {
        guard let url, let documentController, documentController.isViewLoaded else { return }
        store.set(documentController.currentState(), forPath: url.path)
    }

    private func showPlaceholder(_ message: String) {
        documentController = nil
        let container = NSView()
        placeholder.stringValue = message
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        window?.contentViewController = nil
        window?.contentView = container
    }

    // Nothing in the document view takes focus, so keys travel up the responder chain
    // (window → window controller) and land here. Views that do want keys, like a future
    // picker's text field, get them first.
    override func keyDown(with event: NSEvent) {
        if documentController?.handleKeyDown(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        documentController?.handleKeyUp(event)
    }


    func windowDidResignKey(_ notification: Notification) {
        saveState()
        try? store.save()
    }

    func windowWillClose(_ notification: Notification) {
        saveState()
        try? store.save()
        reloader?.stop()
        onClose?()
    }
}

/// Hands `Esc` to the document. NSWindow otherwise consumes it (as `cancelOperation:`)
/// before it can reach the window controller.
final class DocumentWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
}
