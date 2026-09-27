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
    /// Open a file chosen in the picker (the app decides which window it goes in).
    var onOpen: ((URL) -> Void)?
    private let filePicker = PickerView()
    private var pickerPaths: [String] = []
    private var pickerSearch: Task<Void, Never>?
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
        window.hideTrafficLightsUntilHover()
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
            store.touch(url.path)
            controller.onOpenFileRequested = { [weak self] in self?.showFilePicker() }
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

    // MARK: - Opening files

    /// `o` / ⌘O: recent files first, then PDFs under the configured roots as Spotlight finds them.
    func showFilePicker() {
        guard let window, let container = window.contentView else { return }
        pickerSearch?.cancel()
        let recents = FileCatalog.recents(from: store).filter { $0 != url?.path }
        pickerPaths = recents
        filePicker.thumbnail = { [weak self] entry in
            guard let self, self.pickerPaths.indices.contains(entry.id) else { return nil }
            return await FileCatalog.thumbnail(for: self.pickerPaths[entry.id], size: CGSize(width: 26, height: 34))
        }
        filePicker.onChoose = { [weak self] entry in
            guard let self, self.pickerPaths.indices.contains(entry.id) else { return }
            self.onOpen?(URL(fileURLWithPath: self.pickerPaths[entry.id]))
        }
        filePicker.onClose = { [weak self] in
            self?.pickerSearch?.cancel()
            self?.window?.makeFirstResponder(nil)
        }
        filePicker.present(in: container, placeholder: "Open PDF…", entries: entries(for: recents, from: 0), rowHeight: 42)

        let roots = ConfigStore.shared.config.pickerRoots
        guard !roots.isEmpty else {
            filePicker.setStatus(recents.isEmpty ? "no recent files · set [picker] roots in config.toml" : "")
            return
        }
        filePicker.setStatus("searching…")
        pickerSearch = Task { [weak self] in
            let found = await FileCatalog.pdfs(under: roots)
            guard !Task.isCancelled, let self, self.filePicker.isShowing else { return }
            let known = Set(self.pickerPaths).union([self.url?.path].compactMap { $0 })
            let more = found.filter { !known.contains($0) }
            let first = self.pickerPaths.count
            self.pickerPaths += more
            self.filePicker.setStatus("")
            self.filePicker.append(self.entries(for: more, from: first))
        }
    }

    private func entries(for paths: [String], from first: Int) -> [PickerEntry] {
        paths.enumerated().map { offset, path in
            PickerEntry(title: (path as NSString).lastPathComponent,
                        detail: abbreviateHome((path as NSString).deletingLastPathComponent), id: first + offset)
        }
    }

    /// ⌘O
    @objc func openDocument(_ sender: Any?) {
        showFilePicker()
    }

    /// ⌘⇧O: the standard open panel.
    @objc func openWithPanel(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { for url in panel.urls { self?.onOpen?(url) } }
        }
    }

    var isPickerShowing: Bool { filePicker.isShowing }
    var debugPicker: String { filePicker.debugSummary }

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

    private var trafficLights: [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
    }

    /// Minimal chrome: the close/minimize/zoom buttons stay invisible until the pointer is in
    /// the title bar strip, like a full-screen app's.
    func hideTrafficLightsUntilHover() {
        guard let titlebar = standardWindowButton(.closeButton)?.superview else { return }
        for button in trafficLights { button.alphaValue = 0 }
        titlebar.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        setTrafficLights(visible: true)
    }

    override func mouseExited(with event: NSEvent) {
        setTrafficLights(visible: false)
    }

    private func setTrafficLights(visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            for button in trafficLights { button.animator().alphaValue = visible ? 1 : 0 }
        }
    }

    var debugTrafficLightAlpha: CGFloat { trafficLights.first?.alphaValue ?? -1 }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
}
