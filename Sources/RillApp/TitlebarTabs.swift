import AppKit

extension Notification.Name {
    /// A window's title changed, so every tab strip showing it should redraw.
    static let rillTabsChanged = Notification.Name("rillTabsChanged")
}

/// The window's tabs, drawn in the title bar beside the traffic lights. macOS's own tab bar
/// takes a strip of its own below the title bar, so it's kept hidden while this stands in
/// for it. Shown only when the window has more than one tab.
@MainActor
final class TitlebarTabs: NSView {
    private weak var owner: NSWindow?
    private let glass = NSGlassEffectView()
    private let stack = NSStackView()
    private var groupObservations: [NSKeyValueObservation] = []
    private weak var observedGroup: NSWindowTabGroup?

    init(window: NSWindow) {
        owner = window
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        glass.contentView = stack
        glass.cornerRadius = 12
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Tabs come and go with windows opening, closing, merging, and moving to a window of
        // their own; any of those makes some window key, which is the cue to look again.
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, .rillTabsChanged] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A closing window is still in its group until the close finishes.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    func refresh() {
        guard let owner else { return }
        let group = owner.tabGroup
        if group !== observedGroup { observe(group) }
        hideNativeTabBar()

        let windows = group?.windows ?? [owner]
        isHidden = windows.count < 2
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !isHidden else { return }
        for window in windows {
            let tab = TabItem(title: window.title, selected: window === owner)
            tab.onClick = { [weak window] in
                guard let window else { return }
                window.tabGroup?.selectedWindow = window
                window.makeKeyAndOrderFront(nil)
            }
            stack.addArrangedSubview(tab)
        }
    }

    /// macOS won't hide its tab bar while there's more than one tab (`toggleTabBar` does
    /// nothing then), so its view is hidden directly.
    private func hideNativeTabBar() {
        guard let titlebar = superview else { return }
        for view in titlebar.subviews where view !== self && view.subviews.contains(where: {
            String(describing: type(of: $0)).contains("TitlebarAccessory")
        }) {
            view.isHidden = true
        }
    }

    private func observe(_ group: NSWindowTabGroup?) {
        observedGroup = group
        groupObservations = []
        guard let group else { return }
        let changed: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        groupObservations = [
            group.observe(\.windows) { _, _ in changed() },
        ]
    }

    var debugTitles: [String] {
        isHidden ? [] : stack.arrangedSubviews.compactMap { ($0 as? TabItem)?.debugTitle }
    }
}

/// One tab: its window's title, on a tinted capsule when it's the window showing.
@MainActor
private final class TabItem: NSView {
    var onClick: (() -> Void)?
    private let label: NSTextField
    private let selected: Bool

    init(title: String, selected: Bool) {
        label = NSTextField(labelWithString: title)
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        toolTip = title

        label.font = .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateLayer() {
        layer?.backgroundColor = selected ? NSColor.quaternaryLabelColor.cgColor : nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func mouseDown(with event: NSEvent) {}

    var debugTitle: String { selected ? "[\(label.stringValue)]" : label.stringValue }
}
