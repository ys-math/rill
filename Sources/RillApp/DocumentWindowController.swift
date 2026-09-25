import AppKit

/// One window per document. The chrome-free window shell; the document view arrives in milestone 2.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    private(set) var url: URL?
    var onClose: (() -> Void)?

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
        window.isMovableByWindowBackground = true
        window.tabbingMode = .preferred
        window.backgroundColor = .windowBackgroundColor
        window.center()
        super.init(window: window)
        window.delegate = self

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(placeholder)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                placeholder.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                placeholder.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
        load(url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL?) {
        self.url = url
        window?.title = url?.lastPathComponent ?? "rill"
        if let url { window?.representedURL = url }
        placeholder.stringValue = url?.lastPathComponent ?? "rill — no document"
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
