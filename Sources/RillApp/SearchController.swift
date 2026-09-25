import AppKit
import os
import RillCore

private let searchLog = Logger(subsystem: "io.github.ys-math.rill", category: "search")

/// What search needs from the document it's searching.
@MainActor
protocol SearchHost: AnyObject {
    /// The text index for the version on screen (created on first use).
    func textIndex() -> PDFTextIndex?
    /// Where the viewport's top edge is, as (page, y within page).
    func searchAnchor() -> (page: Int, y: CGFloat)
    /// Scroll a match into view.
    func show(_ match: SearchMatch)
    func highlight(_ matches: [SearchMatch], current: Int?)
    /// Put `position` (where a jump is leaving from) in the jump list.
    func recordJump(from position: PagePosition)
    /// Go back to where the search started (Esc).
    func restorePosition(_ position: PagePosition)
    func currentPosition() -> PagePosition
    /// Give keyboard focus back to the document.
    func endEditing()
}

/// `/` `?` `n` `N`: incremental search with Vim's smart-case.
@MainActor
final class SearchController: NSObject, NSTextFieldDelegate {
    private static let debounce: Duration = .milliseconds(80)

    let bar = SearchBar()
    weak var host: SearchHost?

    private(set) var isEditing = false
    private var forward = true
    private var query = SearchQuery("")
    private var matches: [SearchMatch] = []
    private var current: Int?
    /// Where the search began: matches are found from here, and Esc returns here.
    private var origin: (position: PagePosition, anchor: (page: Int, y: CGFloat))?
    private var searchTask: Task<Void, Never>?
    private var warmUp: Task<Void, Never>?

    override init() {
        super.init()
        bar.field.delegate = self
        bar.isHidden = true
    }

    // MARK: - Commands

    func begin(forward: Bool) {
        guard let host else { return }
        self.forward = forward
        origin = (host.currentPosition(), host.searchAnchor())
        isEditing = true
        bar.prefix.stringValue = forward ? "/" : "?"
        bar.field.stringValue = ""
        bar.counter.stringValue = ""
        Overlay.show(bar)
        bar.window?.makeFirstResponder(bar.field)
        if warmUp == nil, let index = host.textIndex() {
            warmUp = Task { await index.warmUp() }
        }
    }

    /// `n` (positive) / `N` (negative), relative to the search's direction as in Vim.
    func next(_ count: Int) {
        guard !matches.isEmpty, let host else { return NSSound.beep() }
        let step = forward ? count : -count
        let index: Int
        if let current {
            index = SearchNavigation.step(from: current, by: step, total: matches.count)
        } else {
            let anchor = host.searchAnchor()
            index = SearchNavigation.firstIndex(in: matches, fromPage: anchor.page, y: anchor.y, forward: step > 0) ?? 0
        }
        host.recordJump(from: host.currentPosition())
        select(index)
    }

    /// Esc in normal mode: stop highlighting (the query is kept for `n`).
    func clearHighlights() {
        current = nil
        host?.highlight([], current: nil)
    }

    /// A new version of the document was loaded: search it again.
    func documentChanged() {
        warmUp?.cancel()
        warmUp = nil
        guard !query.text.isEmpty else { return }
        run(query, jump: false)
    }

    var debugStatus: String {
        "\(isEditing ? "editing" : "idle")/\(query.text)/\(current.map { "\($0 + 1)" } ?? "-")of\(matches.count)"
    }

    // MARK: - Text field

    func controlTextDidChange(_ notification: Notification) {
        run(SearchQuery(bar.field.stringValue), jump: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            accept()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    private func accept() {
        finishEditing()
        if matches.isEmpty, !query.text.isEmpty { NSSound.beep() }
        // The jump from where the search started goes in the jump list.
        if let origin, current != nil { host?.recordJump(from: origin.position) }
    }

    private func cancel() {
        searchTask?.cancel()
        finishEditing()
        clearHighlights()
        if let origin { host?.restorePosition(origin.position) }
    }

    private func finishEditing() {
        isEditing = false
        Overlay.hide(bar)
        host?.endEditing()
    }

    // MARK: - Searching

    private func run(_ query: SearchQuery, jump: Bool) {
        self.query = query
        searchTask?.cancel()
        guard !query.text.isEmpty else {
            matches = []
            current = nil
            bar.counter.stringValue = ""
            host?.highlight([], current: nil)
            if jump, let origin { host?.restorePosition(origin.position) }
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let index = self?.host?.textIndex() else { return }
            self?.bar.counter.stringValue = "…"
            let started = ContinuousClock.now
            let found = await index.search(query)
            if !Task.isCancelled { searchLog.debug("\(found.count) matches for \(query.text, privacy: .public) in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)") }
            guard !Task.isCancelled, let self else { return }
            self.matches = found
            if found.isEmpty {
                self.current = nil
                self.bar.counter.stringValue = "no match"
                self.host?.highlight([], current: nil)
                if jump, let origin = self.origin { self.host?.restorePosition(origin.position) }
            } else if jump, let origin = self.origin {
                let first = SearchNavigation.firstIndex(in: found, fromPage: origin.anchor.page, y: origin.anchor.y,
                                                        forward: self.forward) ?? 0
                self.select(first)
            } else {
                self.current = nil
                self.updateCounter()
                self.host?.highlight(found, current: nil)
            }
        }
    }

    private func select(_ index: Int) {
        current = index
        updateCounter()
        host?.highlight(matches, current: index)
        host?.show(matches[index])
    }

    private func updateCounter() {
        bar.counter.stringValue = current.map { "\($0 + 1)/\(matches.count)" } ?? "\(matches.count)"
    }
}

/// The search field: `/query   3/17`, bottom left.
@MainActor
final class SearchBar: NSView {
    let prefix = Overlay.label("/", color: .secondaryLabelColor)
    let field = NSTextField()
    let counter = Overlay.label("", color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        let panel = Overlay.panel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Overlay.font
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        counter.alignment = .right
        counter.setContentHuggingPriority(.required, for: .horizontal)
        for view in [prefix, field, counter] { panel.addSubview(view) }

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            prefix.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            prefix.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: prefix.trailingAnchor, constant: 2),
            field.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            counter.leadingAnchor.constraint(greaterThanOrEqualTo: field.trailingAnchor, constant: 8),
            counter.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            counter.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
