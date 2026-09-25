import AppKit

/// One window per document, with no visible chrome.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    private(set) var url: URL?
    var onClose: (() -> Void)?

    private var documentController: DocumentViewController?
    private let placeholder = NSTextField(labelWithString: "")

    init(url: URL?) {
        let window = NSWindow(
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

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        placeholder.alignment = .center
        load(url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL?) {
        self.url = url
        guard let window else { return }
        window.title = url?.lastPathComponent ?? "rill"
        window.representedURL = url

        guard let url else { return showPlaceholder("rill — no document") }
        do {
            let controller = DocumentViewController(source: try PDFSource(url: url))
            documentController = controller
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 900, height: 1100))
            DebugSnapshot.runIfRequested(window: window, document: controller)
        } catch {
            showPlaceholder("could not open \(url.lastPathComponent)\n\(error.localizedDescription)")
        }
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

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
