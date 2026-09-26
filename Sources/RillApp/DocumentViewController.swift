import AppKit
import RillCore

/// One open PDF: the scroll view, the page view, and the keyboard.
@MainActor
final class DocumentViewController: NSViewController {
    enum ZoomMode { case fitWidth, fitPage, custom }

    /// A reload that hasn't finished rendering yet gets swapped in anyway after this long.
    private static let reloadSwapTimeout: Duration = .milliseconds(500)

    private(set) var source: PDFSource
    private var layout: PageLayout
    private let scrollView = DocumentScrollView(frame: .zero)
    private var documentView: DocumentView
    private let hud = FrameHUD(frame: .zero)
    private lazy var motion = Motion(scrollView: scrollView)
    private var resolver = KeyResolver()
    private var zoomMode = ZoomMode.fitWidth
    /// keyCode of the key driving continuous scrolling, so its keyUp ends it.
    private var continuousKey: UInt16?
    private var didInitialLayout = false
    private let initialState: DocumentState?
    /// A new version rendering offscreen, waiting to be swapped in.
    private var pendingReload: (view: DocumentView, timeout: Task<Void, Never>)?

    /// `r` was pressed.
    var onReloadRequested: (() -> Void)?

    private let syncIndex: SyncIndex
    /// A forward-search target waiting for the first layout or an in-flight reload.
    private var pendingReveal: [SyncTeXBox]?

    private let search = SearchController()
    private let toast = Toast()
    private let hints = HintController()
    private var jumps = JumpList<PagePosition>(isSame: { a, b in a.page == b.page && abs(a.offset - b.offset) < 0.02 })
    private var marks: [String: PagePosition]
    /// PDFKit view of the version on screen, for search and hints. Built on first use.
    private var textIndexCache: PDFTextIndex?

    init(source: PDFSource, state: DocumentState?) {
        self.source = source
        self.layout = PageLayout(pageSizes: source.pageSizes)
        self.documentView = DocumentView(source: source, layout: layout)
        self.initialState = state
        self.syncIndex = SyncIndex(pdfPath: source.url.path)
        self.marks = state?.marks ?? [:]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        hints.overlay.translatesAutoresizingMaskIntoConstraints = false
        search.bar.translatesAutoresizingMaskIntoConstraints = false
        toast.translatesAutoresizingMaskIntoConstraints = false
        for subview in [scrollView, hints.overlay, search.bar, toast, hud] { container.addSubview(subview) }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hints.overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hints.overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hints.overlay.topAnchor.constraint(equalTo: container.topAnchor),
            hints.overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            search.bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            search.bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            search.bar.widthAnchor.constraint(equalToConstant: 360),
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
        ])
        view = container
        search.host = self
        hints.host = self

        scrollView.onUserScroll = { [weak self] in
            self?.motion.stop()
            self?.hints.cancel()
            self?.zoomMode = .custom
        }
        motion.onFrame = { [weak self] settled in self?.refresh(settled: settled) }

        let center = NotificationCenter.default
        center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(settled: !(self?.motion.isZooming ?? false) && !(self?.scrollView.isLiveMagnifying ?? false)) }
        }
        center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(settled: true) }
        }
        center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportDidResize() }
        }
        scrollView.postsFrameChangedNotifications = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didInitialLayout, scrollView.bounds.width > 0 else { return }
        didInitialLayout = true
        let state = initialState ?? DocumentState(position: PagePosition(page: 0, offset: 0), zoom: .fitWidth)
        let placement = placement(of: state, in: layout)
        zoomMode = placement.mode
        scrollView.magnification = placement.magnification
        scrollView.contentView.scroll(to: placement.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refresh(settled: true)
        wireDocumentView()
        if let boxes = pendingReveal { reveal(boxes) }
    }

    // MARK: - SyncTeX

    /// Forward search. Returns an error message, or nil on success.
    func forwardSearch(_ location: SourceLocation) async -> String? {
        let boxes = await syncIndex.boxes(for: location)
        guard !boxes.isEmpty else {
            return await syncIndex.hasData
                ? "no match for \((location.file as NSString).lastPathComponent):\(location.line)"
                : "no SyncTeX data next to \(source.url.lastPathComponent) (compile with -synctex=1)"
        }
        reveal(boxes)
        return nil
    }

    /// Scrolls the boxes into view (only if they aren't comfortably visible already) and flashes them.
    private func reveal(_ boxes: [SyncTeXBox]) {
        guard didInitialLayout, pendingReload == nil, let first = boxes.first, first.page < layout.pageCount else {
            pendingReveal = boxes
            return
        }
        pendingReveal = nil
        let rect = boxes.map(\.rect).reduce(first.rect) { $0.union($1) }
        let scrolled = reveal(rect, onPage: first.page, recordingJump: true)
        syncLog.debug("reveal page \(first.page + 1) box \(String(describing: first.rect), privacy: .public) (\(boxes.count) boxes) scroll \(scrolled)")
        documentView.flash(rect.offsetBy(dx: layout.pageFrames[first.page].minX, dy: layout.pageFrames[first.page].minY))
    }

    /// Scrolls `rect` (display coordinates on `page`) into view unless it's already comfortably
    /// visible, putting it a third of the way down: context above, room below. Returns whether it scrolled.
    @discardableResult
    private func reveal(_ rect: CGRect, onPage page: Int, recordingJump: Bool) -> Bool {
        let frame = layout.pageFrames[page]
        let target = rect.offsetBy(dx: frame.minX, dy: frame.minY)
        let visible = CGRect(origin: motion.origin, size: motion.viewport)
        let comfortable = visible.insetBy(dx: 0, dy: visible.height * 0.1)
        let inView = comfortable.contains(CGPoint(x: target.midX, y: target.minY))
            && comfortable.contains(CGPoint(x: target.midX, y: target.maxY))
        guard !inView else { return false }
        if recordingJump { jumps.record(currentPosition()) }
        documentView.ensureThumbnails(page...page + 1)
        motion.jump(toY: target.minY - visible.height / 3)
        return true
    }

    private func inverseSearch(at point: CGPoint) {
        let index = layout.pageIndex(atY: point.y)
        let frame = layout.pageFrames[index]
        guard frame.contains(point) else { return }
        let syncIndex = syncIndex
        Task {
            guard let location = await syncIndex.location(page: index, x: point.x - frame.minX, y: point.y - frame.minY) else {
                syncLog.notice("inverse search: no source for page \(index + 1)")
                NSSound.beep()
                return
            }
            InverseSearch.open(location)
        }
    }

    private func wireDocumentView() {
        documentView.onCommandClick = { [weak self] in self?.inverseSearch(at: $0) }
    }

    // MARK: - State and reload

    /// Where the viewer is now, in layout-independent terms.
    func currentState() -> DocumentState {
        let zoom: ZoomSetting = switch zoomMode {
        case .fitWidth: .fitWidth
        case .fitPage: .fitPage
        case .custom: .magnification(Double(scrollView.magnification))
        }
        return DocumentState(position: layout.position(atY: motion.origin.y), x: Double(motion.origin.x), zoom: zoom,
                             marks: marks)
    }

    /// Shows a new version of the document at the same place. The new version renders
    /// offscreen first and is swapped in within a single frame once its visible tiles are
    /// ready (or after a short timeout, with thumbnails standing in).
    func replace(with newSource: PDFSource, noticed: ContinuousClock.Instant = .now) {
        cancelPendingReload()
        let newLayout = PageLayout(pageSizes: newSource.pageSizes)
        let newView = DocumentView(source: newSource, layout: newLayout)
        let target = placement(of: currentState(), in: newLayout)
        let visible = CGRect(origin: target.origin,
                             size: CGSize(width: scrollView.contentSize.width / target.magnification,
                                          height: scrollView.contentSize.height / target.magnification))

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.reloadSwapTimeout)
            if !Task.isCancelled {
                reloadLog.notice("swap timed out waiting for tiles")
                self?.swapIn(newView, source: newSource, layout: newLayout, noticed: noticed)
            }
        }
        pendingReload = (newView, timeout)
        newView.prepare(visible: visible, magnification: target.magnification, backingScale: backingScale) { [weak self] in
            self?.swapIn(newView, source: newSource, layout: newLayout, noticed: noticed)
        }
    }

    private func swapIn(_ newView: DocumentView, source newSource: PDFSource, layout newLayout: PageLayout,
                        noticed: ContinuousClock.Instant) {
        guard pendingReload?.view === newView else { return }
        pendingReload?.timeout.cancel()
        pendingReload = nil

        // Measure again: the user may have scrolled while the new version rendered.
        let target = placement(of: currentState(), in: newLayout)
        motion.stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        documentView.teardown()
        source = newSource
        layout = newLayout
        documentView = newView
        scrollView.documentView = newView
        scrollView.magnification = target.magnification
        scrollView.contentView.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        CATransaction.commit()
        refresh(settled: true)
        wireDocumentView()
        textIndexCache = nil
        hints.cancel()
        search.documentChanged()
        if let boxes = pendingReveal { reveal(boxes) }
        reloadLog.debug("swapped in \((ContinuousClock.now - noticed).formatted(.units(allowed: [.milliseconds])), privacy: .public) after the change")
    }

    private func cancelPendingReload() {
        guard let pending = pendingReload else { return }
        pending.timeout.cancel()
        pending.view.teardown()
        pendingReload = nil
    }

    private func placement(of state: DocumentState, in layout: PageLayout) -> (magnification: CGFloat, origin: CGPoint, mode: ZoomMode) {
        let viewport = scrollView.contentSize
        let (magnification, mode): (CGFloat, ZoomMode) = switch state.zoom {
        case .fitWidth: (layout.fitWidthMagnification(viewportWidth: viewport.width), .fitWidth)
        case .fitPage: (layout.fitPageMagnification(page: state.position.page, viewport: viewport), .fitPage)
        case .magnification(let m): (CGFloat(m), .custom)
        }
        let clamped = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
        return (clamped, CGPoint(x: state.x, y: layout.y(for: state.position)), mode)
    }

    private var backingScale: CGFloat { view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidAppear() {
        super.viewDidAppear()
        // A keyUp that lands in another window would otherwise leave continuous scrolling running.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: view.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.continuousKey != nil else { return }
                self.continuousKey = nil
                self.motion.endContinuous()
            }
        }
    }

    // MARK: - Keys

    /// Returns false for keys rill doesn't handle, so they continue up the responder chain.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let token = event.keyToken else { return false }
        if hints.isActive { return hints.feed(token) }
        // Auto-repeat of a held motion key is handled by continuous scrolling; others repeat normally.
        if event.isARepeat, continuousKey == event.keyCode { return true }
        switch resolver.feed(token) {
        case .pending:
            return true
        case .unbound:
            return token == "<Esc>"
        case .escape:
            perform(.clearHighlights, count: nil)
            return true
        case .actionWithArgument(let action, let argument, let count):
            perform(action, count: count, argument: argument)
            return true
        case .action(let action, let count):
            if action.isContinuous, count == nil, !event.isARepeat {
                beginContinuous(action, keyCode: event.keyCode)
            } else {
                perform(action, count: count)
            }
            return true
        }
    }

    /// One line of state for the debug snapshot log.
    var debugStatus: String {
        let p = currentPosition()
        return "page=\(p.page + 1) offset=\(String(format: "%.3f", p.offset)) x=\(Int(motion.origin.x)) "
            + "toast=\(toast.debugMessage.isEmpty ? "-" : toast.debugMessage) hints=\(hints.debugCount) search=\(search.debugStatus) marks=\(marks.keys.sorted().joined()) jumps=\(jumps.count) "
            + "pasteboard=\(NSPasteboard.general.string(forType: .string)?.prefix(30) ?? "")"
    }

    /// Feeds a key sequence as if typed, without continuous scrolling. For debugging and tests.
    func feed(keys sequence: String) {
        for token in KeyMap.tokens(of: sequence) {
            if hints.isActive { _ = hints.feed(token); continue }
            switch resolver.feed(token) {
            case .action(let action, let count): perform(action, count: count)
            case .actionWithArgument(let action, let argument, let count): perform(action, count: count, argument: argument)
            case .escape: perform(.clearHighlights, count: nil)
            case .pending, .unbound: break
            }
        }
    }

    /// `Esc`. AppKit delivers it as the `cancelOperation:` command instead of a key press.
    func handleEscape() {
        if hints.isActive {
            hints.cancel()
            return
        }
        if case .escape = resolver.feed("<Esc>") { perform(.clearHighlights, count: nil) }
    }

    func handleKeyUp(_ event: NSEvent) {
        guard event.keyCode == continuousKey else { return }
        continuousKey = nil
        motion.endContinuous()
    }

    private func beginContinuous(_ action: Action, keyCode: UInt16) {
        continuousKey = keyCode
        let (axis, direction): (Motion.Axis, CGFloat) = switch action {
        case .scrollDown: (.vertical, 1)
        case .scrollUp: (.vertical, -1)
        case .scrollRight: (.horizontal, 1)
        default: (.horizontal, -1)
        }
        motion.beginContinuous(axis: axis, direction: direction, step: smallStep(axis))
    }

    // MARK: - Actions

    func perform(_ action: Action, count: Int?, argument: KeyToken? = nil) {
        let n = CGFloat(count ?? 1)
        let viewport = motion.viewport
        switch action {
        case .scrollDown: motion.scroll(by: n * smallStep(.vertical), axis: .vertical)
        case .scrollUp: motion.scroll(by: -n * smallStep(.vertical), axis: .vertical)
        case .scrollRight: motion.scroll(by: n * smallStep(.horizontal), axis: .horizontal)
        case .scrollLeft: motion.scroll(by: -n * smallStep(.horizontal), axis: .horizontal)
        case .halfPageDown: motion.scroll(by: n * viewport.height / 2, axis: .vertical)
        case .halfPageUp: motion.scroll(by: -n * viewport.height / 2, axis: .vertical)
        case .screenDown: motion.scroll(by: n * viewport.height * 0.9, axis: .vertical)
        case .screenUp: motion.scroll(by: -n * viewport.height * 0.9, axis: .vertical)
        case .pageNext: jump(toPage: pageAtTop() + Int(n))
        case .pagePrev:
            // Like `[[`: first back to the top of the current page, then to earlier pages.
            let current = pageAtTop()
            let atTop = motion.origin.y <= layout.topOffset(ofPage: current) + 2
            jump(toPage: current - (atTop ? Int(n) : Int(n) - 1))
        case .firstPage: jump(toPage: (count ?? 1) - 1, recordingJump: true)
        case .goToPage: jump(toPage: count.map { $0 - 1 } ?? layout.pageCount - 1, recordingJump: true)
        case .zoomIn: zoom(to: scrollView.magnification * pow(1.25, n))
        case .zoomOut: zoom(to: scrollView.magnification / pow(1.25, n))
        case .zoomReset: zoom(to: 1)
        case .fitWidth: fitWidth(animated: true)
        case .fitPage: fitPage()
        case .toggleFrameHUD: hud.toggle()
        case .reload: onReloadRequested?()
        case .jumpBack:
            for _ in 0..<Int(n) { if let p = jumps.back(from: currentPosition()) { go(to: p) } else { NSSound.beep(); break } }
        case .jumpForward:
            for _ in 0..<Int(n) { if let p = jumps.forward() { go(to: p) } else { NSSound.beep(); break } }
        case .setMark:
            guard let name = argument, name != "'" else { return NSSound.beep() }
            marks[name] = currentPosition()
            toast.show("mark \(name) set")
        case .goToMark:
            let target = argument == "'" ? jumps.lastJumpOrigin : argument.flatMap { marks[$0] }
            guard let target else {
                toast.show(argument == "'" ? "no previous jump" : "no mark \(argument ?? "")")
                return
            }
            jumps.record(currentPosition())
            go(to: target)
        case .searchForward: search.begin(forward: true)
        case .searchBackward: search.begin(forward: false)
        case .searchNext: search.next(Int(n))
        case .searchPrevious: search.next(-Int(n))
        case .clearHighlights: search.clearHighlights()
        case .hintFollowLink: hints.begin(.followLink)
        case .hintInverseSearch: hints.begin(.inverseSearch)
        case .hintYankLine: hints.begin(.yankLine)
        }
    }

    /// `j`/`k` step: a tenth of the viewport.
    private func smallStep(_ axis: Motion.Axis) -> CGFloat {
        (axis == .vertical ? motion.viewport.height : motion.viewport.width) / 10
    }

    private func pageAtTop() -> Int {
        // Bias slightly down so a page whose top is just above the viewport still counts.
        layout.pageIndex(atY: motion.origin.y + layout.gap)
    }

    private func jump(toPage index: Int, recordingJump: Bool = false) {
        if recordingJump { jumps.record(currentPosition()) }
        let page = min(max(index, 0), layout.pageCount - 1)
        let y = layout.topOffset(ofPage: page)
        let pagesInView = max(Int((motion.viewport.height / (layout.pageFrames[page].height + layout.gap)).rounded(.up)), 1)
        documentView.ensureThumbnails(page...(page + pagesInView))
        motion.jump(toY: y)
    }

    func currentPosition() -> PagePosition {
        layout.position(atY: motion.origin.y)
    }

    /// Scroll to a remembered position (marks, jump list).
    private func go(to position: PagePosition) {
        let page = min(max(position.page, 0), layout.pageCount - 1)
        documentView.ensureThumbnails(page...page + 1)
        motion.jump(toY: layout.y(for: position))
    }

    private func zoom(to magnification: CGFloat) {
        zoomMode = .custom
        let viewPoint = CGPoint(x: scrollView.contentSize.width / 2, y: scrollView.contentSize.height / 2)
        let anchor = CGPoint(x: motion.origin.x + motion.viewport.width / 2, y: motion.origin.y + motion.viewport.height / 2)
        motion.zoom(to: magnification, anchor: anchor, viewPoint: viewPoint)
    }

    private func fitWidth(animated: Bool) {
        zoomMode = .fitWidth
        let target = layout.fitWidthMagnification(viewportWidth: scrollView.contentSize.width)
        // Keep the top edge's document position; recenter horizontally.
        let anchor = CGPoint(x: motion.origin.x + motion.viewport.width / 2, y: motion.origin.y)
        let final = CGPoint(x: layout.size.width / 2, y: motion.origin.y)
        let viewPoint = CGPoint(x: scrollView.contentSize.width / 2, y: 0)
        if animated {
            motion.zoom(to: target, anchor: anchor, finalAnchor: final, viewPoint: viewPoint)
        } else {
            scrollView.magnification = target
            scrollView.contentView.scroll(to: CGPoint(x: final.x - viewPoint.x / target, y: final.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            refresh(settled: true)
        }
    }

    private func fitPage() {
        zoomMode = .fitPage
        let page = layout.pageIndex(atY: motion.origin.y + motion.viewport.height / 2)
        let frame = layout.pageFrames[page]
        let target = layout.fitPageMagnification(page: page, viewport: scrollView.contentSize)
        let viewPoint = CGPoint(x: scrollView.contentSize.width / 2, y: scrollView.contentSize.height / 2)
        let anchor = CGPoint(x: motion.origin.x + motion.viewport.width / 2, y: motion.origin.y + motion.viewport.height / 2)
        motion.zoom(to: target, anchor: anchor, finalAnchor: CGPoint(x: frame.midX, y: frame.midY), viewPoint: viewPoint)
    }

    private func viewportDidResize() {
        guard didInitialLayout else { return }
        hints.cancel()
        switch zoomMode {
        case .fitWidth: fitWidth(animated: false)
        case .fitPage, .custom: refresh(settled: true)
        }
    }

    private func refresh(settled: Bool) {
        documentView.updateContent(visible: scrollView.contentView.bounds, magnification: scrollView.magnification,
                                   backingScale: backingScale, settled: settled)
    }
}

// MARK: - Search and hints

extension DocumentViewController: SearchHost, HintHost {
    func textIndex() -> PDFTextIndex? {
        if textIndexCache == nil { textIndexCache = PDFTextIndex(data: source.data) }
        return textIndexCache
    }

    func searchAnchor() -> (page: Int, y: CGFloat) {
        let y = motion.origin.y
        let page = layout.pageIndex(atY: y)
        return (page, y - layout.pageFrames[page].minY)
    }

    func show(_ match: SearchMatch) {
        guard match.page < layout.pageCount else { return }
        reveal(match.rect, onPage: match.page, recordingJump: false)
    }

    func highlight(_ matches: [SearchMatch], current: Int?) {
        documentView.setHighlights(matches, current: current)
    }

    func recordJump(from position: PagePosition) {
        jumps.record(position)
    }

    func restorePosition(_ position: PagePosition) {
        go(to: position)
    }

    func endEditing() {
        view.window?.makeFirstResponder(nil)
    }

    func visibleRegions() -> [Int: CGRect] {
        let visible = CGRect(origin: motion.origin, size: motion.viewport)
        guard let pages = layout.pages(inYRange: visible.minY, visible.maxY) else { return [:] }
        var regions: [Int: CGRect] = [:]
        for index in pages {
            let frame = layout.pageFrames[index]
            let part = visible.intersection(frame)
            if !part.isNull { regions[index] = part.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        }
        return regions
    }

    func overlayPoint(page: Int, point: CGPoint) -> CGPoint {
        let frame = layout.pageFrames[page]
        let documentPoint = CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)
        return hints.overlay.convert(documentPoint, from: documentView)
    }

    func hintsUnavailable(_ kind: HintKind) {
        toast.show(kind == .followLink ? "no links on screen" : "no text on screen")
    }

    func hintChosen(_ target: HintTarget, kind: HintKind) {
        let frame = layout.pageFrames[target.page]
        switch (kind, target) {
        case (.followLink, .link(let link)):
            switch link.destination {
            case .url(let url):
                NSWorkspace.shared.open(url)
            case .page(let index, let point):
                guard index < layout.pageCount else { return NSSound.beep() }
                jumps.record(currentPosition())
                if let point {
                    // A little context above the destination (usually a heading or equation).
                    let top = layout.pageFrames[index].minY + point.y - motion.viewport.height * 0.05
                    documentView.ensureThumbnails(index...index + 1)
                    motion.jump(toY: top)
                } else {
                    jump(toPage: index)
                }
            }
        case (.inverseSearch, .line(let line)):
            documentView.flash(line.rect.offsetBy(dx: frame.minX, dy: frame.minY))
            let syncIndex = syncIndex
            Task {
                guard let location = await syncIndex.location(page: line.page, x: line.rect.midX, y: line.rect.midY) else {
                    return NSSound.beep()
                }
                InverseSearch.open(location)
            }
        case (.yankLine, .line(let line)):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line.text, forType: .string)
            documentView.flash(line.rect.offsetBy(dx: frame.minX, dy: frame.minY))
        default:
            break
        }
    }
}
