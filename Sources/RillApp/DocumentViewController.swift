import AppKit
import RillCore

/// One open PDF: the scroll view, the page view, and the keyboard.
@MainActor
final class DocumentViewController: NSViewController {
    enum ZoomMode { case fitWidth, fitPage, custom }

    let source: PDFSource
    private let layout: PageLayout
    private let scrollView = DocumentScrollView(frame: .zero)
    private let documentView: DocumentView
    private let hud = FrameHUD(frame: .zero)
    private lazy var motion = Motion(scrollView: scrollView)
    private var resolver = KeyResolver()
    private var zoomMode = ZoomMode.fitWidth
    /// keyCode of the key driving continuous scrolling, so its keyUp ends it.
    private var continuousKey: UInt16?
    private var didInitialLayout = false

    init(source: PDFSource) {
        self.source = source
        self.layout = PageLayout(pageSizes: source.pageSizes)
        self.documentView = DocumentView(source: source, layout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(hud)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
        ])
        view = container

        scrollView.onUserScroll = { [weak self] in
            self?.motion.stop()
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
        scrollView.magnification = layout.fitWidthMagnification(viewportWidth: scrollView.contentSize.width)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refresh(settled: true)
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
        // Auto-repeat of a held motion key is handled by continuous scrolling; others repeat normally.
        if event.isARepeat, continuousKey == event.keyCode { return true }
        switch resolver.feed(token) {
        case .pending:
            return true
        case .unbound:
            return token == "<Esc>"
        case .action(let action, let count):
            if action.isContinuous, count == nil, !event.isARepeat {
                beginContinuous(action, keyCode: event.keyCode)
            } else {
                perform(action, count: count)
            }
            return true
        }
    }

    var debugOrigin: CGPoint { motion.origin }


    /// Feeds a key sequence as if typed, without continuous scrolling. For debugging and tests.
    func feed(keys sequence: String) {
        for token in KeyMap.tokens(of: sequence) {
            if case .action(let action, let count) = resolver.feed(token) { perform(action, count: count) }
        }
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

    func perform(_ action: Action, count: Int?) {
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
        case .firstPage: jump(toPage: (count ?? 1) - 1)
        case .goToPage: jump(toPage: count.map { $0 - 1 } ?? layout.pageCount - 1)
        case .zoomIn: zoom(to: scrollView.magnification * pow(1.25, n))
        case .zoomOut: zoom(to: scrollView.magnification / pow(1.25, n))
        case .zoomReset: zoom(to: 1)
        case .fitWidth: fitWidth(animated: true)
        case .fitPage: fitPage()
        case .toggleFrameHUD: hud.toggle()
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

    private func jump(toPage index: Int) {
        let page = min(max(index, 0), layout.pageCount - 1)
        let y = layout.topOffset(ofPage: page)
        let pagesInView = max(Int((motion.viewport.height / (layout.pageFrames[page].height + layout.gap)).rounded(.up)), 1)
        documentView.ensureThumbnails(page...(page + pagesInView))
        motion.jump(toY: y)
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
        switch zoomMode {
        case .fitWidth: fitWidth(animated: false)
        case .fitPage, .custom: refresh(settled: true)
        }
    }

    private func refresh(settled: Bool) {
        documentView.updateContent(visible: scrollView.contentView.bounds,
                                   magnification: scrollView.magnification, settled: settled)
    }
}
