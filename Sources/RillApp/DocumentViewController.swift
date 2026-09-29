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
    private let backdrop = Backdrop()
    private lazy var motion = Motion(scrollView: scrollView)
    private var resolver = KeyResolver(keymap: ConfigStore.shared.config.keymap)
    private var zoomMode = ZoomMode.fitWidth
    /// keyCode of the key driving continuous scrolling, so its keyUp ends it.
    private var continuousKey: UInt16?
    private var didInitialLayout = false
    private let initialState: DocumentState?
    /// A new version rendering offscreen, waiting to be swapped in.
    private var pendingReload: (view: DocumentView, timeout: Task<Void, Never>, markChanges: Bool)?

    /// `r` was pressed.
    var onReloadRequested: (() -> Void)?
    /// `o` was pressed.
    var onOpenFileRequested: (() -> Void)?
    /// `⌃^` was pressed.
    var onAlternateRequested: (() -> Void)?
    private let outlinePicker = PickerView()
    /// Link previews: the first for a link in the document, each further one for a link inside
    /// the card below it.
    private var previews: [LinkPreview] = []
    private let visual = VisualController()
    private var hoverTask: Task<Void, Never>?
    private var cardHoverTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// The card whose links the current hints label, if they're in a card.
    private var cardHintLevel: Int?
    /// The link just clicked; hovering it shows no preview until the pointer leaves it.
    private var clickedLink: LinkTarget?
    private var outline: [OutlineEntry] = []

    private let syncIndex: SyncIndex
    /// A forward-search target waiting for the first layout or an in-flight reload.
    private var pendingReveal: [SyncTeXBox]?

    private let search = SearchController()
    private let toast = Toast()
    private let pill = StatusPill()
    private let cheatsheet = Cheatsheet()
    /// `i` overrides the config's dark mode for this window.
    private var darkOverride: Bool?
    private var appearanceObservation: NSKeyValueObservation?
    /// Single-page mode (`s`): the first page of the one row shown. Nil when scrolling continuously.
    private var singlePage: Int?
    /// Single-page mode: turns the page when the trackpad or wheel pushes on past its edge.
    private var overscroll = Overscroll()
    /// `S` overrides the config's spread for this window.
    private var spreadOverride: PageLayout.Spread?
    /// `c` overrides the config's trim for this window.
    private var trimOverride: Bool?
    /// The latest measured margins. Laid out on newer versions too until they're measured.
    private var trimProfile: TrimProfile?
    /// The version `trimProfile` was measured on.
    private weak var trimMeasuredSource: PDFSource?
    private var trimTask: Task<Void, Never>?
    private let hints = HintController()
    private var jumps = JumpList<PagePosition>(isSame: { a, b in a.page == b.page && abs(a.offset - b.offset) < 0.02 })
    private var marks: [String: PagePosition]
    /// PDFKit view of the version on screen, for search and hints. Built on first use.
    private var textIndexCache: PDFTextIndex?

    init(source: PDFSource, state: DocumentState?) {
        self.source = source
        self.layout = PageLayout(pageSizes: source.pageSizes, spread: ConfigStore.shared.config.spread,
                                 gap: CGFloat(ConfigStore.shared.config.pageGap))
        self.documentView = DocumentView(source: source, layout: layout, recolor: Self.recolor(darkOverride: nil))
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
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        hints.overlay.translatesAutoresizingMaskIntoConstraints = false
        search.bar.translatesAutoresizingMaskIntoConstraints = false
        toast.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        cheatsheet.translatesAutoresizingMaskIntoConstraints = false
        for subview in [backdrop, scrollView, hints.overlay, search.bar, toast, pill, cheatsheet, hud] { container.addSubview(subview) }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            pill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            cheatsheet.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            cheatsheet.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
        ])
        view = container
        search.host = self
        hints.host = self
        hints.onActiveChange = { [weak self] active in self?.pill.mode = active ? "HINT" : nil }
        visual.host = self
        visual.onModeChange = { [weak self] mode in self?.pill.mode = mode }

        scrollView.onUserScroll = { [weak self] in
            self?.motion.stop()
            self?.hints.cancel()
            self?.hidePreviews()
            self?.zoomMode = .custom
        }
        scrollView.interceptScroll = { [weak self] event in self?.overscroll(event) ?? false }
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

        center.addObserver(forName: .rillConfigDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configDidChange() }
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appearanceDidChange() } }
        }
    }

    // MARK: - Config and appearance

    private static func wantsDark(override: Bool?) -> Bool {
        if let override { return override }
        switch ConfigStore.shared.config.darkMode {
        case .on: return true
        case .off: return false
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// How pages should be recoloured now: nil in light mode.
    private static func recolor(darkOverride: Bool?) -> PaperRecolor? {
        guard wantsDark(override: darkOverride) else { return nil }
        let config = ConfigStore.shared.config
        return PaperRecolor(paper: config.darkPaper, ink: config.darkInk)
    }

    private func configDidChange() {
        let config = ConfigStore.shared.config
        resolver = KeyResolver(keymap: config.keymap)
        applyBackground()
        applyCorners()
        if layout != makeLayout(for: source) || documentView.recolor != Self.recolor(darkOverride: darkOverride) {
            rebuild()
        }
        measureTrimIfNeeded()
    }

    private func applyBackground() {
        backdrop.apply(ConfigStore.shared.config, scrollView: scrollView, window: view.window)
    }

    private func applyCorners() {
        documentView.pageCornerRadius = ConfigStore.shared.config.cornerRadius
    }

    private func appearanceDidChange() {
        if documentView.recolor != Self.recolor(darkOverride: darkOverride) { rebuild() }
    }

    /// Re-renders the same version with current settings (dark mode, page gap, spread, trim),
    /// swapping it in the same way a reload does.
    private func rebuild() {
        replace(with: source)
    }

    private var spread: PageLayout.Spread { spreadOverride ?? ConfigStore.shared.config.spread }
    private var trimEnabled: Bool { trimOverride ?? ConfigStore.shared.config.trim }

    private func makeLayout(for source: PDFSource) -> PageLayout {
        PageLayout(pageSizes: source.pageSizes, trims: trimEnabled ? trimProfile?.trims(for: source.pageSizes) : nil,
                   spread: spread, gap: CGFloat(ConfigStore.shared.config.pageGap))
    }

    /// When trimming, measures the margins of the version on screen (once per version) in the
    /// background, and lays it out again if they changed.
    private func measureTrimIfNeeded() {
        guard trimEnabled, trimMeasuredSource !== source else { return }
        trimTask?.cancel()
        let source = source
        trimTask = Task { [weak self] in
            let profile = await Task.detached(priority: .userInitiated) {
                TrimProfile(contentBoxes: source.contentBoxes(), pageSizes: source.pageSizes)
            }.value
            guard let self, !Task.isCancelled, self.source === source else { return }
            self.trimMeasuredSource = source
            guard profile != self.trimProfile else { return }
            self.trimProfile = profile
            // A newer version is on its way in; it's measured once it's swapped in.
            if self.trimEnabled, self.pendingReload == nil { self.rebuild() }
        }
    }

    /// Config problems stay up longer than command feedback: they need reading.
    func showToast(_ message: String, briefly: Bool = false) {
        briefly ? toast.show(message) : toast.show(message, for: .seconds(5))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didInitialLayout, scrollView.bounds.width > 0 else { return }
        didInitialLayout = true
        let state = initialState
            ?? DocumentState(position: PagePosition(page: 0, offset: 0), zoom: ConfigStore.shared.config.defaultZoom)
        let placement = placement(of: state, in: layout)
        zoomMode = placement.mode
        scrollView.magnification = placement.magnification
        scrollView.contentView.scroll(to: placement.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refresh(settled: true)
        wireDocumentView()
        if let boxes = pendingReveal { reveal(boxes) }
        measureTrimIfNeeded()
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
        let origin = layout.origin(ofPage: first.page)
        documentView.flash(rect.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// Scrolls `rect` (display coordinates on `page`) into view unless it's already comfortably
    /// visible, putting it a third of the way down: context above, room below. Returns whether it scrolled.
    @discardableResult
    private func reveal(_ rect: CGRect, onPage page: Int, recordingJump: Bool) -> Bool {
        let origin = layout.origin(ofPage: page)
        let target = rect.offsetBy(dx: origin.x, dy: origin.y)
        let visible = CGRect(origin: motion.origin, size: motion.viewport)
        let comfortable = visible.insetBy(dx: 0, dy: visible.height * 0.1)
        let inView = comfortable.contains(CGPoint(x: target.midX, y: target.minY))
            && comfortable.contains(CGPoint(x: target.midX, y: target.maxY))
        guard !inView else { return false }
        if recordingJump { jumps.record(currentPosition()) }
        ensureThumbnails(fromPage: page)
        goY(target.minY - visible.height / 3)
        return true
    }

    private func inverseSearch(at point: CGPoint) {
        let index = layout.pageIndex(at: point)
        guard layout.pageFrames[index].contains(point) else { return }
        let local = layout.pagePoint(point, onPage: index)
        let syncIndex = syncIndex
        Task {
            guard let location = await syncIndex.location(page: index, x: local.x, y: local.y) else {
                syncLog.notice("inverse search: no source for page \(index + 1)")
                NSSound.beep()
                return
            }
            InverseSearch.open(location)
        }
    }

    private func wireDocumentView() {
        documentView.onCommandClick = { [weak self] in self?.inverseSearch(at: $0) }
        documentView.onClick = { [weak self] in self?.click(at: $0) }
        documentView.onHover = { [weak self] in self?.hover(at: $0) }
        applyCorners()
    }

    // MARK: - Links: click, hover, preview


    /// The link under a document point, if any.
    private func link(at point: CGPoint) async -> LinkTarget? {
        let page = layout.pageIndex(at: point)
        guard layout.pageFrames[page].contains(point) else { return nil }
        return await link(onPage: page, at: layout.pagePoint(point, onPage: page))
    }

    /// The link at a point of a page (display coordinates), if any.
    private func link(onPage page: Int, at point: CGPoint) async -> LinkTarget? {
        guard let index = textIndex() else { return nil }
        return await index.links(onPage: page).first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private static func same(_ a: LinkTarget?, _ b: LinkTarget?) -> Bool {
        guard let a, let b else { return false }
        return a.page == b.page && a.rect == b.rect
    }

    private func click(at point: CGPoint) {
        Task { [weak self] in
            guard let self, let link = await self.link(at: point) else { return }
            // Following a link needs no preview of it: drop a pending or shown one, and keep it
            // away while the pointer stays on that link.
            self.hoverTask?.cancel()
            self.hidePreviews()
            self.clickedLink = link
            self.follow(link)
        }
    }

    /// Resting the pointer on a link shows its preview; moving off hides it (after a moment, so
    /// the pointer can move onto the card).
    private func hover(at point: CGPoint?) {
        hoverTask?.cancel()
        guard let point else { return scheduleHide(from: 0) }
        // Over a card: the card handles the pointer.
        let inView = view.convert(point, from: documentView)
        if previews.contains(where: { $0.isShowing && $0.frame.contains(inView) }) { return }
        hoverTask = Task { [weak self] in
            guard let self else { return }
            let link = await self.link(at: point)
            guard !Task.isCancelled else { return }
            if let clicked = self.clickedLink {
                if Self.same(link, clicked) { return }
                self.clickedLink = nil
            }
            if Self.same(link, self.previews.first?.target) {
                self.hideTask?.cancel()
                return
            }
            self.scheduleHide(from: 0)
            guard let link else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.showPreview(link, fromHover: true)
        }
    }

    /// The pointer over the card at `level` (a point from its top-left), or leaving it (nil):
    /// resting on a link inside the card opens a card for it on top.
    private func cardHover(level: Int, at local: CGPoint?) {
        cardHoverTask?.cancel()
        guard let local else { return scheduleHide(from: level) }
        let card = previews[level]
        // Under a card above this one: that card handles the pointer.
        let inView = card.convert(CGPoint(x: local.x, y: card.bounds.height - local.y), to: view)
        if previews.dropFirst(level + 1).contains(where: { $0.isShowing && $0.frame.contains(inView) }) { return }
        hideTask?.cancel()
        guard let (page, point) = card.pagePoint(at: local) else { return scheduleHide(from: level + 1) }
        cardHoverTask = Task { [weak self] in
            guard let self else { return }
            let link = await self.link(onPage: page, at: point)
            guard !Task.isCancelled else { return }
            let next = self.previews.indices.contains(level + 1) ? self.previews[level + 1].target : nil
            if Self.same(link, next) { return }
            self.scheduleHide(from: level + 1)
            guard let link else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.showPreview(link, fromHover: true, level: level + 1)
        }
    }

    /// A click inside a card follows the link under it.
    private func cardClick(level: Int, at local: CGPoint) {
        guard let (page, point) = previews[level].pagePoint(at: local) else { return }
        Task { [weak self] in
            guard let self, let link = await self.link(onPage: page, at: point) else { return }
            self.hidePreviews()
            self.follow(link)
        }
    }

    private var isPreviewing: Bool { previews.contains { $0.isShowing } }

    /// The card at `level`, made on first use.
    private func card(at level: Int) -> LinkPreview {
        while previews.count <= level {
            let card = LinkPreview(), cardLevel = previews.count
            card.onHover = { [weak self] in self?.cardHover(level: cardLevel, at: $0) }
            card.onClick = { [weak self] in self?.cardClick(level: cardLevel, at: $0) }
            card.onScroll = { [weak self] event in
                self?.hidePreviews()
                self?.scrollView.scrollWheel(with: event)
            }
            previews.append(card)
        }
        return previews[level]
    }

    /// Hides the cards from `level` up (all of them by default).
    private func hidePreviews(from level: Int = 0) {
        hideTask?.cancel()
        for card in previews.dropFirst(level) where card.isShowing || card.target != nil { card.hide() }
    }

    /// Hides the hover-opened cards from `level` up in a moment, unless the pointer reaches one
    /// of them (or the link it came from) first.
    private func scheduleHide(from level: Int) {
        hideTask?.cancel()
        guard previews.indices.contains(level), previews[level].target != nil, previews[level].fromHover else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.hidePreviews(from: level)
        }
    }

    /// `p` / `f` with a card up: hints on the links inside the top card.
    private func beginCardHints(_ kind: HintKind) {
        guard let level = previews.lastIndex(where: { $0.isShowing }) else { return }
        let card = previews[level]
        var regions: [Int: CGRect] = [:]
        for region in card.regions { regions[region.page] = region.rect }
        guard !regions.isEmpty else { return NSSound.beep() }
        cardHintLevel = level
        let overlay = hints.overlay
        hints.begin(kind, in: HintScope(regions: regions) { [weak card] page, point in
            guard let card, let rect = card.rect(CGRect(origin: point, size: CGSize(width: 1, height: 1)), onPage: page, in: overlay)
            else { return CGPoint(x: -100, y: -100) }
            return CGPoint(x: rect.minX, y: overlay.isFlipped ? rect.minY : rect.maxY)
        })
    }

    private func follow(_ link: LinkTarget) {
        switch link.destination {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .page(let index, let point):
            guard index < layout.pageCount else { return NSSound.beep() }
            jumps.record(currentPosition())
            pill.flash()
            if let point {
                // A little context above the destination (usually a heading or equation).
                ensureThumbnails(fromPage: index)
                goY(layout.origin(ofPage: index).y + point.y - motion.viewport.height * 0.05)
            } else {
                jump(toPage: index)
            }
        }
    }

    /// A card next to the link showing where it goes: a crop of the target page, sharp at the
    /// current zoom, or a web link's address.
    /// `level` 0 is a link in the document; higher levels are links inside the card below.
    private func showPreview(_ link: LinkTarget, fromHover: Bool, level: Int = 0) {
        // Where the link is on screen.
        let anchor: CGRect
        if level == 0 {
            let origin = layout.origin(ofPage: link.page)
            anchor = view.convert(link.rect.offsetBy(dx: origin.x, dy: origin.y), from: documentView)
        } else {
            guard previews.indices.contains(level - 1), previews[level - 1].isShowing,
                  let rect = previews[level - 1].rect(link.rect, onPage: link.page, in: view)
            else { return }
            anchor = rect
        }
        hidePreviews(from: level + 1)
        let card = card(at: level)
        card.target = link
        card.fromHover = fromHover
        switch link.destination {
        case .url(let url):
            card.show(image: nil, size: CGSize(width: 520, height: 34), text: url.absoluteString, near: anchor, in: view, beneath: hints.overlay)
        case .page(let index, let point):
            guard index < layout.pageCount else { return }
            // The shown part of the page: trimmed like the page itself.
            let trims = layout.trims
            let height: CGFloat = 230
            let magnification = scrollView.magnification
            let scale = min(magnification * backingScale, 4)
            let source = source, recolor = documentView.recolor, textIndex = textIndex()
            Task { [weak self] in
                let trim = trims[index]
                var parts: [PagePart]
                if let (term, environment) = await textIndex?.indexTarget(for: link, maxHeight: 600) {
                    // An index entry's link names only the page: show the definition its term is
                    // in, or else where the term is, a little way down.
                    if let environment {
                        parts = environment
                    } else {
                        let top = max(min(term.midY - height * 0.3, trim.maxY - height), trim.minY)
                        parts = [PagePart(page: index, rect: CGRect(x: trim.minX, y: top, width: trim.width, height: height))]
                    }
                } else if let point, var environment = await textIndex?.environment(page: index, anchor: point, maxHeight: 600) {
                    // The whole theorem, equation or reference the link names, on every page it
                    // runs across; from the destination if it's well above (a figure over its caption).
                    let first = environment[0].rect
                    if point.y < first.minY - 12 {
                        environment[0].rect = CGRect(x: first.minX, y: point.y, width: first.width, height: first.maxY - point.y)
                    }
                    parts = environment
                } else {
                    let top = (point?.y ?? 0) - 18
                    parts = [PagePart(page: index, rect: CGRect(x: trim.minX, y: top, width: trim.width, height: height))]
                }
                // Within the page as shown (environments come with their margin).
                let regions = parts.map { PagePart(page: $0.page, rect: $0.rect.intersection(trims[$0.page])) }
                    .filter { !$0.rect.isEmpty }
                guard !regions.isEmpty else { return }
                let image = await Task.detached(priority: .userInitiated) { () -> UncheckedImageBox? in
                    let images = regions.compactMap { region -> CGImage? in
                        let r = region.rect
                        let pixels = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
                        guard let plain = source.render(page: region.page, pixelRect: pixels, scale: scale) else { return nil }
                        return recolor.flatMap { $0.apply(plain) } ?? plain
                    }
                    guard images.count == regions.count else { return nil }
                    return LinkPreview.stack(images).map(UncheckedImageBox.init)
                }.value
                guard let self, Self.same(card.target, link), let image else { return }
                let size = CGSize(width: (regions.map(\.rect.width).max() ?? 0) * magnification,
                                  height: regions.map(\.rect.height).reduce(0, +) * magnification)
                card.show(image: image.image, size: size, text: nil, regions: regions, near: anchor, in: self.view, beneath: self.hints.overlay)
            }
        }
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
    /// `markChanges`: a recompile, so show what changed (not for re-renders like dark mode).
    func replace(with newSource: PDFSource, noticed: ContinuousClock.Instant = .now, markChanges: Bool = false) {
        cancelPendingReload()
        let newLayout = makeLayout(for: newSource)
        let newView = DocumentView(source: newSource, layout: newLayout, recolor: Self.recolor(darkOverride: darkOverride))
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
        pendingReload = (newView, timeout, markChanges)
        newView.prepare(visible: visible, magnification: target.magnification, backingScale: backingScale) { [weak self] in
            self?.swapIn(newView, source: newSource, layout: newLayout, noticed: noticed)
        }
    }

    private func swapIn(_ newView: DocumentView, source newSource: PDFSource, layout newLayout: PageLayout,
                        noticed: ContinuousClock.Instant) {
        guard let pending = pendingReload, pending.view === newView else { return }
        pending.timeout.cancel()
        pendingReload = nil
        // The outgoing version's text, to compare with the new one afterwards.
        let outgoing = pending.markChanges && ConfigStore.shared.config.changeMarkers
            ? (index: textIndexCache ?? PDFTextIndex(data: source.data), pages: layout.pages(inYRange: motion.origin.y, motion.origin.y + motion.viewport.height))
            : nil

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
        visual.cancel()
        hidePreviews()
        search.documentChanged()
        if let outgoing, let oldIndex = outgoing.index, let pages = outgoing.pages {
            markChanges(from: oldIndex, around: pages, in: newView)
        }
        applySinglePage()
        pill.flash()
        if let boxes = pendingReveal { reveal(boxes) }
        measureTrimIfNeeded()
        reloadLog.debug("swapped in \((ContinuousClock.now - noticed).formatted(.units(allowed: [.milliseconds])), privacy: .public) after the change")
    }

    /// Compares the text lines around the viewport before and after a recompile (matched by an
    /// LCS, so text that only moved doesn't count) and marks new or edited lines in the margin.
    private func markChanges(from oldIndex: PDFTextIndex, around pages: ClosedRange<Int>, in view: DocumentView) {
        guard let newIndex = textIndex() else { return }
        let pageCount = layout.pageCount
        Task { [weak self] in
            func lines(_ index: PDFTextIndex, _ count: Int) async -> [TextLine] {
                let range = max(pages.lowerBound - 1, 0)...min(pages.upperBound + 1, count - 1)
                guard !range.isEmpty else { return [] }
                return await index.lines(in: Dictionary(uniqueKeysWithValues: range.map { ($0, CGRect.infinite) }))
            }
            // Page numbers move relative to the text whenever content crosses a page break;
            // they aren't edits.
            let isPageNumber: (TextLine) -> Bool = { $0.text.count <= 6 && $0.text.allSatisfy { $0.isNumber || "ivxlcIVXLC".contains($0) } }
            let oldCount = await oldIndex.pageCount
            let old = await lines(oldIndex, oldCount).filter { !isPageNumber($0) }
            let new = await lines(newIndex, pageCount).filter { !isPageNumber($0) }
            let key: (TextLine) -> String = { $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            let changed = ChangeDetector.changedBands(old: old.map(key), new: new.map(key))

            var bands: [Int: [ClosedRange<CGFloat>]] = [:]
            for band in changed {
                if band.isEmpty {
                    // A deletion: a tick where the removed text used to be.
                    guard let next = new.indices.contains(band.lowerBound) ? new[band.lowerBound] : new.last else { continue }
                    let y = new.indices.contains(band.lowerBound) ? next.rect.minY - 2 : next.rect.maxY + 2
                    bands[next.page, default: []].append(y...y)
                    continue
                }
                // One bar per page the changed lines are on.
                for (page, group) in Dictionary(grouping: new[band], by: \.page) {
                    let top = group.map(\.rect.minY).min()!, bottom = group.map(\.rect.maxY).max()!
                    bands[page, default: []].append(top...bottom)
                }
            }
            reloadLog.debug("change markers: \(old.count) → \(new.count) lines, changed \(String(describing: changed), privacy: .public)")
            guard let self, self.documentView === view, !bands.isEmpty else { return }
            self.documentView.showChangeMarkers(bands)
        }
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

    override func viewWillAppear() {
        super.viewWillAppear()
        applyBackground()
    }

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
        if cheatsheet.isShowing {
            cheatsheet.hide()
            return true
        }
        if hints.isActive { return hints.feed(token) }
        if isPreviewing {
            // Enter follows the top card's link; the hint keys label the links inside it;
            // anything else closes the cards and does what it always does.
            if token == "<CR>", let target = previews.last(where: { $0.isShowing })?.target {
                hidePreviews()
                follow(target)
                return true
            }
            let result = resolver.feed(token)
            switch result {
            case .pending(let display):
                pill.pending = display
                return true
            case .action(.hintPreviewLink, _):
                pill.pending = nil
                beginCardHints(.previewLink)
                return true
            case .action(.hintFollowLink, _):
                pill.pending = nil
                beginCardHints(.followLink)
                return true
            default:
                hidePreviews()
                return handle(result, token: token, of: event)
            }
        }
        if visual.isActive { return visual.feed(token) }
        // Auto-repeat of a held motion key is handled by continuous scrolling; others repeat normally.
        if event.isARepeat, continuousKey == event.keyCode { return true }
        return handle(resolver.feed(token), token: token, of: event)
    }

    private func handle(_ result: KeyResolver.Result, token: KeyToken, of event: NSEvent) -> Bool {
        if case .pending(let display) = result { pill.pending = display } else { pill.pending = nil }
        switch result {
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
            + "markers=\(documentView.debugChangeMarkers) single=\(singlePage.map { "\($0 + 1)" } ?? "-") dark=\(documentView.dark) gap=\(Int(layout.gap)) pill=\(pill.debugText.isEmpty ? "-" : pill.debugText) "
            + "cheatsheet=\(cheatsheet.isShowing) toast=\(toast.debugMessage.isEmpty ? "-" : toast.debugMessage) hints=\(hints.debugCount) search=\(search.debugStatus) marks=\(marks.keys.sorted().joined()) jumps=\(jumps.count) "
            + "pasteboard=\(NSPasteboard.general.string(forType: .string)?.prefix(30) ?? "") "
            + "outline=\(outlinePicker.isShowing ? outlinePicker.debugSummary : "-")"
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
        pill.pending = nil
        if cheatsheet.isShowing {
            cheatsheet.hide()
            return
        }
        if hints.isActive {
            hints.cancel()
            return
        }
        // The top card only: the one it came from stays.
        if let top = previews.lastIndex(where: { $0.isShowing }) {
            hidePreviews(from: top)
            return
        }
        if visual.isActive {
            _ = visual.feed("<Esc>")
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
        // Single-page mode: at the page's edge, the key turns the page instead of pressing on.
        if action == .scrollDown, turnsPage(forward: true) { return turnPage(by: 1) }
        if action == .scrollUp, turnsPage(forward: false) { return turnPage(by: -1) }
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
        if action.category == .jump || action.category == .zoom, action != .toggleStatus, action != .toggleDarkMode, action != .setMark {
            pill.flash()
        }
        // Single-page mode: scrolling on past the page's edge turns the page.
        if [.scrollDown, .halfPageDown, .screenDown].contains(action), turnsPage(forward: true) { return turnPage(by: 1) }
        if [.scrollUp, .halfPageUp, .screenUp].contains(action), turnsPage(forward: false) { return turnPage(by: -1) }
        switch action {
        case .scrollDown: motion.scroll(by: n * smallStep(.vertical), axis: .vertical)
        case .scrollUp: motion.scroll(by: -n * smallStep(.vertical), axis: .vertical)
        case .scrollRight: motion.scroll(by: n * smallStep(.horizontal), axis: .horizontal)
        case .scrollLeft: motion.scroll(by: -n * smallStep(.horizontal), axis: .horizontal)
        case .halfPageDown: motion.scroll(by: n * viewport.height / 2, axis: .vertical)
        case .halfPageUp: motion.scroll(by: -n * viewport.height / 2, axis: .vertical)
        case .screenDown: motion.scroll(by: n * viewport.height * 0.9, axis: .vertical)
        case .screenUp: motion.scroll(by: -n * viewport.height * 0.9, axis: .vertical)
        case .pageNext: jump(toRow: rowAtTop() + Int(n))
        case .pagePrev:
            // Like `[[`: first back to the top of the current page (or spread), then to earlier ones.
            let current = rowAtTop()
            let atTop = motion.origin.y <= layout.topOffset(ofRow: current) + 2
            jump(toRow: current - (atTop ? Int(n) : Int(n) - 1))
        case .firstPage: jump(toPage: (count ?? 1) - 1, recordingJump: true)
        case .goToPage: jump(toPage: count.map { $0 - 1 } ?? layout.pageCount - 1, recordingJump: true)
        case .zoomIn: zoom(to: scrollView.magnification * pow(ConfigStore.shared.config.zoomStep, n))
        case .zoomOut: zoom(to: scrollView.magnification / pow(ConfigStore.shared.config.zoomStep, n))
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
        case .toggleDarkMode:
            darkOverride = !documentView.dark
            rebuild()
            toast.show(darkOverride == true ? "dark mode" : "light mode")
        case .toggleStatus:
            pill.pinned.toggle()
            if !pill.pinned { pill.flash() }
        case .showCheatsheet: cheatsheet.show(keymap: ConfigStore.shared.config.keymap)
        case .closeDocument: view.window?.performClose(nil)
        case .openFile: onOpenFileRequested?()
        case .editConfig: if let problem = ConfigStore.shared.edit() { toast.show(problem, for: .seconds(5)) }
        case .showOutline: showOutline()
        case .toggleSinglePage: toggleSinglePage()
        case .alternateFile: onAlternateRequested?()
        case .nextTab, .previousTab:
            guard let window = view.window, (window.tabGroup?.windows.count ?? 1) > 1 else {
                return toast.show("no other tab")
            }
            action == .nextTab ? window.selectNextTab(nil) : window.selectPreviousTab(nil)
        case .hintPreviewLink: hints.begin(.previewLink)
        case .visualMode: hints.begin(.visual(linewise: false))
        case .visualLineMode: hints.begin(.visual(linewise: true))
        case .toggleSpread:
            let next: PageLayout.Spread = switch layout.spread {
            case .off: .pairs
            case .pairs: .book
            case .book: .off
            }
            spreadOverride = next
            rebuild()
            let message = switch next {
            case .off: "one page per row"
            case .pairs: "two-page spread"
            case .book: "two-page spread, book style"
            }
            toast.show(message)
        case .toggleTrim:
            trimOverride = !trimEnabled
            if layout != makeLayout(for: source) { rebuild() }
            measureTrimIfNeeded()
            toast.show(trimEnabled ? "margins trimmed" : "whole pages")
        }
    }

    /// `j`/`k` step: `scroll_step` of the viewport.
    private func smallStep(_ axis: Motion.Axis) -> CGFloat {
        (axis == .vertical ? motion.viewport.height : motion.viewport.width) * ConfigStore.shared.config.scrollStep
    }

    private func rowAtTop() -> Int {
        // Single-page mode centres a short row, so the viewport's top can sit above it.
        if let page = singlePage { return layout.rowIndex(ofPage: page) }
        // Bias slightly down so a row whose top is just above the viewport still counts.
        return layout.rowIndex(atY: motion.origin.y + layout.gap)
    }

    private func jump(toPage index: Int, recordingJump: Bool = false) {
        if recordingJump { jumps.record(currentPosition()) }
        jump(toRow: layout.rowIndex(ofPage: index))
    }

    private func jump(toRow index: Int) {
        let row = min(max(index, 0), layout.rowCount - 1)
        let y = layout.topOffset(ofRow: row)
        let rowsInView = max(Int((motion.viewport.height / (layout.rowFrames[row].height + layout.gap)).rounded(.up)), 1)
        documentView.ensureThumbnails(layout.rows[row].lowerBound...layout.rows[min(row + rowsInView, layout.rowCount - 1)].upperBound)
        goY(y)
    }

    /// Thumbnails for the row page `index` is in and the row after it, so a jump there never lands on blank pages.
    private func ensureThumbnails(fromPage index: Int) {
        let row = layout.rowIndex(ofPage: index)
        documentView.ensureThumbnails(layout.rows[row].lowerBound...layout.rows[min(row + 1, layout.rowCount - 1)].upperBound)
    }

    func currentPosition() -> PagePosition {
        layout.position(atY: motion.origin.y)
    }

    private func showOutline() {
        guard let index = textIndex() else { return }
        Task { [weak self] in
            let entries = await index.outline()
            guard let self else { return }
            guard !entries.isEmpty else { return self.toast.show("no outline in this PDF") }
            self.outline = entries
            self.outlinePicker.onChoose = { [weak self] in self?.goToOutlineEntry($0.id) }
            self.outlinePicker.onClose = { [weak self] in self?.view.window?.makeFirstResponder(nil) }
            self.outlinePicker.present(
                in: self.view, placeholder: "Go to section…",
                entries: entries.enumerated().map { i, e in PickerEntry(title: e.title, detail: "p. \(e.page + 1)", indent: e.depth, id: i) },
                rowHeight: 26)
            // Start at the section you're reading.
            let here = self.currentPosition().page
            if let current = entries.lastIndex(where: { $0.page <= here }) { self.outlinePicker.select(row: current) }
        }
    }

    private func goToOutlineEntry(_ id: Int) {
        guard outline.indices.contains(id) else { return }
        let entry = outline[id]
        guard entry.page < layout.pageCount else { return }
        jumps.record(currentPosition())
        pill.flash()
        if let point = entry.point {
            ensureThumbnails(fromPage: entry.page)
            goY(layout.origin(ofPage: entry.page).y + point.y - motion.viewport.height * 0.05)
        } else {
            jump(toPage: entry.page)
        }
    }

    // MARK: - Single page

    /// Every programmatic jump goes through here, so single-page mode can turn to the page
    /// the target is on first. `y` is the viewport's new top edge.
    private func goY(_ y: CGFloat) {
        guard let current = singlePage else { return motion.jump(toY: y) }
        // The row the viewer will be looking at: a third of the way down the viewport.
        let row = layout.rowIndex(atY: y + motion.viewport.height / 3)
        if row == layout.rowIndex(ofPage: current) {
            motion.jump(toY: y)
        } else {
            singlePage = layout.rows[row].lowerBound
            applySinglePage()
            motion.cut(toY: y)
        }
    }

    private func toggleSinglePage() {
        if singlePage == nil {
            singlePage = layout.pageIndex(atY: motion.origin.y + motion.viewport.height / 2)
            applySinglePage()
            fitPage()
            toast.show("single page")
        } else {
            singlePage = nil
            applySinglePage()
            toast.show("continuous")
        }
    }

    /// Restricts scrolling and drawing to the current page, or spread (or lifts the restriction).
    private func applySinglePage() {
        let clip = scrollView.contentView as? CenteringClipView
        guard let page = singlePage, !layout.rows.isEmpty else {
            clip?.allowedRect = nil
            motion.ySpan = nil
            documentView.showOnly(pages: nil)
            return
        }
        // The layout may have changed (a reload, or a spread toggled): show the row the page is in now.
        let row = layout.rowIndex(ofPage: page)
        singlePage = layout.rows[row].lowerBound
        let frame = layout.rowFrames[row]
        let area = CGRect(x: 0, y: frame.minY - layout.gap / 2, width: layout.size.width, height: frame.height + layout.gap)
        clip?.allowedRect = area
        motion.ySpan = area.minY...area.maxY
        documentView.showOnly(pages: layout.rows[row])
    }

    /// In single-page mode, a scroll that would go past the page's edge turns the page instead.
    private func turnsPage(forward: Bool) -> Bool {
        guard singlePage != nil, let limit = motion.yLimit else { return false }
        return forward ? motion.origin.y >= limit.upperBound - 1 : motion.origin.y <= limit.lowerBound + 1
    }

    /// Trackpad or wheel scrolling on past the page's edge turns the page. Returns whether the
    /// event was consumed.
    private func overscroll(_ event: NSEvent) -> Bool {
        guard singlePage != nil else { return false }
        let phase: Overscroll.Phase
        if !event.momentumPhase.isEmpty {
            phase = .momentum
        } else if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            phase = .began
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            phase = .ended
        } else if event.phase.isEmpty {
            phase = .wheel
        } else {
            phase = .changed
        }
        // Positive scrollingDeltaY scrolls toward the top. A wheel reports lines, not points.
        let delta = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 20)
        switch overscroll.feed(delta: delta, phase: phase, atStart: turnsPage(forward: false), atEnd: turnsPage(forward: true)) {
        case .pass: return false
        case .swallow: return true
        case .turn(let direction):
            turnPage(by: direction)
            return true
        }
    }

    private func turnPage(by delta: Int) {
        guard let page = singlePage else { return }
        let target = layout.rowIndex(ofPage: page) + delta
        guard layout.rows.indices.contains(target) else { return NSSound.beep() }
        pill.flash()
        let frame = layout.rowFrames[target]
        // Forward lands on the new page's top; backward on its bottom, as if scrolling on.
        let y = delta > 0 ? frame.minY - layout.gap / 2 : frame.maxY + layout.gap / 2 - motion.viewport.height
        singlePage = layout.rows[target].lowerBound
        applySinglePage()
        motion.cut(toY: y)
    }

    /// Scroll to a remembered position (marks, jump list).
    private func go(to position: PagePosition) {
        ensureThumbnails(fromPage: position.page)
        goY(layout.y(for: position))
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
        let frame = layout.rowFrames[layout.rowIndex(ofPage: page)]
        let target = layout.fitPageMagnification(page: page, viewport: scrollView.contentSize)
        let viewPoint = CGPoint(x: scrollView.contentSize.width / 2, y: scrollView.contentSize.height / 2)
        let anchor = CGPoint(x: motion.origin.x + motion.viewport.width / 2, y: motion.origin.y + motion.viewport.height / 2)
        motion.zoom(to: target, anchor: anchor, finalAnchor: CGPoint(x: frame.midX, y: frame.midY), viewPoint: viewPoint)
    }

    private func viewportDidResize() {
        guard didInitialLayout else { return }
        hints.cancel()
        applySinglePage()
        switch zoomMode {
        case .fitWidth: fitWidth(animated: false)
        case .fitPage, .custom: refresh(settled: true)
        }
    }

    private func refresh(settled: Bool) {
        pill.update(page: layout.pageIndex(atY: motion.origin.y + motion.viewport.height / 2) + 1,
                    of: layout.pageCount, zoom: scrollView.magnification)
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
        return (page, y - layout.origin(ofPage: page).y)
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
            let part = visible.intersection(layout.pageFrames[index])
            let origin = layout.origin(ofPage: index)
            if !part.isNull { regions[index] = part.offsetBy(dx: -origin.x, dy: -origin.y) }
        }
        return regions
    }

    func overlayPoint(page: Int, point: CGPoint) -> CGPoint {
        let origin = layout.origin(ofPage: page)
        let documentPoint = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
        return hints.overlay.convert(documentPoint, from: documentView)
    }

    func hintsUnavailable(_ kind: HintKind) {
        toast.show(kind.targetsLinks ? "no links on screen" : "no text on screen")
    }

    func hintChosen(_ target: HintTarget, kind: HintKind) {
        let origin = layout.origin(ofPage: target.page)
        switch (kind, target) {
        case (.followLink, .link(let link)):
            cardHintLevel = nil
            hidePreviews()
            follow(link)
        case (.previewLink, .link(let link)):
            // From hints inside a card: a card on top of it.
            let level = isPreviewing ? cardHintLevel.map { $0 + 1 } ?? 0 : 0
            cardHintLevel = nil
            showPreview(link, fromHover: false, level: level)
        case (.visual(let linewise), .line(let line)):
            visual.begin(at: TextPosition(page: line.page, index: line.range.location), linewise: linewise)
        case (.inverseSearch, .line(let line)):
            documentView.flash(line.rect.offsetBy(dx: origin.x, dy: origin.y))
            let syncIndex = syncIndex
            // A PDF line can mix words from several source lines; ask about its first word, not its middle.
            let x = line.rect.minX + min(2, line.rect.width / 2)
            Task {
                guard let location = await syncIndex.location(page: line.page, x: x, y: line.rect.midY) else {
                    return NSSound.beep()
                }
                InverseSearch.open(location)
            }
        case (.yankLine, .line(let line)):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line.text, forType: .string)
            documentView.flash(line.rect.offsetBy(dx: origin.x, dy: origin.y))
        default:
            break
        }
    }
}

// MARK: - Visual mode

extension DocumentViewController: VisualHost {
    func showSelection(_ rects: [Int: [CGRect]], cursor: (page: Int, rect: CGRect)?) {
        documentView.setSelection(rects, cursor: cursor)
    }

    func revealCursor(page: Int, rect: CGRect) {
        guard page < layout.pageCount else { return }
        reveal(rect, onPage: page, recordingJump: false)
    }

    func visualEnded(copied: String?) {
        guard let copied else { return }
        toast.show(copied.isEmpty ? "nothing copied" : "copied \(copied.count) characters")
    }
}

/// CGImages are immutable; these carry them across a task hop.
private struct UncheckedImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
