import AppKit
import RillCore

/// `g?`: every binding in effect (including remaps from the config), grouped by category.
@MainActor
final class Cheatsheet: NSView {
    private let panel = Overlay.panel()
    private var backing: NSView!

    init() {
        super.init(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        // A reference card should be readable over any page, blur or not.
        let backing = NSView()
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        backing.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(backing)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            backing.topAnchor.constraint(equalTo: panel.topAnchor),
            backing.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        self.backing = backing
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShowing: Bool { !isHidden }

    func show(keymap: [String: Action]) {
        panel.subviews.filter { $0 !== backing }.forEach { $0.removeFromSuperview() }

        // Every sequence bound to each action, shortest first.
        var keys: [Action: [String]] = [:]
        for (sequence, action) in keymap { keys[action, default: []].append(sequence) }
        func column(_ categories: [Action.Category]) -> NSGridView {
            let grid = NSGridView()
            grid.rowSpacing = 3
            grid.columnSpacing = 14
            for category in categories {
                let actions = Action.allCases.filter { $0.category == category && keys[$0] != nil }
                guard !actions.isEmpty else { continue }
                let header = Overlay.label(category.rawValue.uppercased(), color: .tertiaryLabelColor)
                if grid.numberOfRows > 0 { grid.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView]) }
                grid.addRow(with: [header, NSGridCell.emptyContentView])
                for action in actions {
                    let sequences = keys[action]!.sorted { ($0.count, $0) < ($1.count, $1) }
                    grid.addRow(with: [
                        Overlay.label(sequences.map(KeyMap.display).joined(separator: "  "), color: .labelColor),
                        Overlay.label(action.summary, color: .secondaryLabelColor),
                    ])
                }
            }
            grid.column(at: 0).xPlacement = .trailing
            // Keep each column at its natural height so the shorter one isn't stretched.
            grid.setContentHuggingPriority(.required, for: .vertical)
            grid.setContentCompressionResistancePriority(.required, for: .vertical)
            return grid
        }

        let columns = NSStackView(views: [column([.scroll, .jump, .zoom]), column([.search, .hints, .other])])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36
        let footer = Overlay.label("any key to close", color: .tertiaryLabelColor)
        let stack = NSStackView(views: [columns, footer])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
        ])
        Overlay.show(self)
    }

    func hide() {
        Overlay.hide(self)
    }
}
