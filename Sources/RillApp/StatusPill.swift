import AppKit

/// Bottom-right status: `12 / 148 · 125%`. Appears briefly after jumps, zooms and reloads,
/// stays while keys are pending or a mode is active, and stays for good when pinned (`g.`).
@MainActor
final class StatusPill: NSView {
    private static let visibleFor: Duration = .milliseconds(1500)

    private let label = Overlay.label()
    private var hideTask: Task<Void, Never>?
    private var position = ""

    /// Keys typed so far in an unfinished sequence ("5", "g", "m").
    var pending: String? { didSet { refresh() } }
    /// A mode name while one is active ("HINT").
    var mode: String? { didSet { refresh() } }
    var pinned = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        let panel = Overlay.panel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        panel.addSubview(label)
        label.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -5),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Cheap; called on every scroll frame.
    func update(page: Int, of pageCount: Int, zoom: CGFloat) {
        let text = "\(page) / \(pageCount) · \(Int((zoom * 100).rounded()))%"
        guard text != position else { return }
        position = text
        refresh()
    }

    /// Show for a moment (after a jump, zoom or reload).
    func flash() {
        Overlay.show(self)
        scheduleHide()
    }

    var debugText: String { isHidden ? "" : label.stringValue }

    private func refresh() {
        label.stringValue = [mode, pending, position].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ")
        if pinned || pending != nil || mode != nil {
            hideTask?.cancel()
            Overlay.show(self)
        } else if !isHidden, hideTask == nil {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !pinned, pending == nil, mode == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            if !self.pinned, self.pending == nil, self.mode == nil { Overlay.hide(self) }
        }
    }
}
