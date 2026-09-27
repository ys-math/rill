import AppKit

/// A short message at the bottom centre that fades out, for feedback on commands that
/// otherwise have no visible effect ("mark a set", "no links on screen").
@MainActor
final class Toast: NSView {

    private let label = Overlay.label()
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        let panel = Overlay.panel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        panel.addSubview(label)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ message: String, for duration: Duration = .milliseconds(1400)) {
        label.stringValue = message
        Overlay.show(self)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            Overlay.hide(self)
        }
    }

    var debugMessage: String { isHidden ? "" : label.stringValue }
}
