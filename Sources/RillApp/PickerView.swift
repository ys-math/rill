import AppKit
import RillCore

/// One row in a picker.
struct PickerEntry {
    /// Matched first and shown bold where it matched (a file name, an outline title).
    var title: String
    /// Shown dimmer; also matched, at a discount (a folder path, a page number).
    var detail: String
    /// Outline nesting.
    var indent = 0
    /// Index into the caller's own list, returned on choice.
    var id: Int
}

/// Spotlight-style chooser: a query field over a ranked list. Used by the file picker (`o`)
/// and the outline picker (`t`). ↑/↓ or ⌃p/⌃n move, Enter chooses, Esc closes.
@MainActor
final class PickerView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let maxResults = 300
    /// Title matches outrank detail matches by this much.
    private static let titleBonus = 20.0

    var onChoose: ((PickerEntry) -> Void)?
    var onClose: (() -> Void)?
    /// Loads a row's thumbnail, for pickers that have them.
    var thumbnail: ((PickerEntry) async -> NSImage?)?

    let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let status = Overlay.label("", color: .tertiaryLabelColor)
    private var heightConstraint: NSLayoutConstraint!

    private var entries: [PickerEntry] = []
    private var results: [(entry: PickerEntry, positions: [Int])] = []
    private var rowHeight: CGFloat = 26
    private var thumbnails: [Int: NSImage] = [:]

    init() {
        super.init(frame: .zero)
        let panel = Overlay.panel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        let backing = NSView()
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        backing.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(backing)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        status.alignment = .right
        for view in [field, separator, scroll, status] { panel.addSubview(view) }

        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            backing.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            backing.topAnchor.constraint(equalTo: panel.topAnchor),
            backing.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            widthAnchor.constraint(equalToConstant: 580),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            heightConstraint,
            status.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            status.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Presenting

    /// Shows the picker in `container`, near the top like Spotlight, and focuses the query.
    func present(in container: NSView, placeholder: String, entries: [PickerEntry], rowHeight: CGFloat) {
        removeFromSuperview()
        translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: container.centerXAnchor),
            topAnchor.constraint(equalTo: container.topAnchor, constant: max(48, container.bounds.height * 0.14)),
        ])
        self.rowHeight = rowHeight
        table.rowHeight = rowHeight
        field.placeholderString = placeholder
        field.stringValue = ""
        thumbnails = [:]
        self.entries = entries
        rank()
        Overlay.show(self)
        window?.makeFirstResponder(field)
    }

    /// More entries arrived (e.g. from Spotlight); keeps the selection's place.
    func append(_ more: [PickerEntry]) {
        entries += more
        rank()
    }

    func setStatus(_ text: String) {
        status.stringValue = text
    }

    var isShowing: Bool { superview != nil && !isHidden }

    /// Moves the selection (with an empty query, rows are in the caller's order).
    func select(row: Int) {
        guard results.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    var debugSummary: String {
        let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow].entry.title : "-"
        return "\(results.count) results, selected \(selected)"
    }

    func close() {
        guard superview != nil else { return }
        removeFromSuperview()
        onClose?()
    }

    // MARK: - Ranking

    private func rank() {
        let query = field.stringValue
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = entries.prefix(Self.maxResults).map { ($0, []) }
        } else {
            var scored: [(entry: PickerEntry, positions: [Int], score: Double)] = []
            for entry in entries {
                if let m = Fuzzy.match(query, in: entry.title) {
                    scored.append((entry, m.positions, m.score + Self.titleBonus))
                } else if let m = Fuzzy.match(query, in: entry.detail) {
                    scored.append((entry, [], m.score))
                }
            }
            // Stable for equal scores, so earlier (more recent) entries stay first.
            results = scored.enumerated()
                .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
                .prefix(Self.maxResults)
                .map { ($0.element.entry, $0.element.positions) }
        }
        table.reloadData()
        let visibleRows = min(max(results.count, 1), 12)
        heightConstraint.constant = CGFloat(visibleRows) * rowHeight
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        if status.stringValue.isEmpty || !status.stringValue.hasSuffix("…") {
            status.stringValue = results.isEmpty ? "no matches" : "\(results.count)\(results.count == Self.maxResults ? "+" : "")"
        }
    }

    // MARK: - Keys

    func controlTextDidChange(_ obj: Notification) {
        rank()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)): choose(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), results.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        choose(row: table.clickedRow)
    }

    private func choose(row: Int) {
        guard results.indices.contains(row) else { return NSSound.beep() }
        let entry = results[row].entry
        close()
        onChoose?(entry)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PickerCell.identifier, owner: nil) as? PickerCell) ?? PickerCell()
        let result = results[row]
        cell.configure(result.entry, positions: result.positions, showsImage: thumbnail != nil)
        if let thumbnail {
            let id = result.entry.id
            if let cached = thumbnails[id] {
                cell.imageView?.image = cached
            } else {
                cell.imageView?.image = nil
                Task { [weak self, weak cell] in
                    guard let image = await thumbnail(result.entry) else { return }
                    self?.thumbnails[id] = image
                    if cell?.entryID == id { cell?.imageView?.image = image }
                }
            }
        }
        return cell
    }
}

/// A picker row: optional thumbnail, title with matched characters in bold, and detail.
@MainActor
private final class PickerCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerCell")

    private(set) var entryID = -1
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let thumb = NSImageView()
    private var leading: NSLayoutConstraint!
    private var thumbWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = thumb
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.borderWidth = 0.5
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingHead
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for view in [thumb, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        leading = thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        thumbWidth = thumb.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            leading, thumbWidth,
            thumb.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            thumb.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: PickerEntry, positions: [Int], showsImage: Bool) {
        entryID = entry.id
        leading.constant = 10 + CGFloat(entry.indent) * 16
        thumbWidth.constant = showsImage ? 26 : 0
        thumb.isHidden = !showsImage
        let text = NSMutableAttributedString(string: entry.title, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let characters = Array(entry.title)
        var utf16Offset = 0
        var offsets: [Int] = []
        for c in characters { offsets.append(utf16Offset); utf16Offset += c.utf16.count }
        for p in positions where p < characters.count {
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold),
                              range: NSRange(location: offsets[p], length: characters[p].utf16.count))
        }
        title.attributedStringValue = text
        detail.stringValue = entry.detail
    }
}
