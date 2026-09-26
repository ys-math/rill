import AppKit
import RillCore

enum HintKind {
    case followLink
    case inverseSearch
    case yankLine
}

enum HintTarget {
    case link(LinkTarget)
    case line(TextLine)

    var page: Int {
        switch self {
        case .link(let link): link.page
        case .line(let line): line.page
        }
    }

    var rect: CGRect {
        switch self {
        case .link(let link): link.rect
        case .line(let line): line.rect
        }
    }
}

/// What hint mode needs from the document.
@MainActor
protocol HintHost: AnyObject {
    func textIndex() -> PDFTextIndex?
    /// The visible part of each on-screen page, in that page's display coordinates.
    func visibleRegions() -> [Int: CGRect]
    /// A page point in the hint overlay's coordinates.
    func overlayPoint(page: Int, point: CGPoint) -> CGPoint
    /// Nothing to label on screen.
    func hintsUnavailable(_ kind: HintKind)
    func hintChosen(_ target: HintTarget, kind: HintKind)
}

/// `f` / `F` / `yf`: label on-screen targets with home-row keys, act on the one typed.
@MainActor
final class HintController {
    let overlay = HintOverlay()
    weak var host: HintHost?

    private(set) var isActive = false { didSet { if isActive != oldValue { onActiveChange?(isActive) } } }
    /// Hint mode started or ended (for the status pill's mode indicator).
    var onActiveChange: ((Bool) -> Void)?
    private var kind = HintKind.followLink
    private var hints: [(label: String, target: HintTarget)] = []
    private var typed = ""
    private var loading: Task<Void, Never>?

    func begin(_ kind: HintKind) {
        guard let host, let index = host.textIndex() else { return NSSound.beep() }
        cancel()
        self.kind = kind
        isActive = true
        let regions = host.visibleRegions()
        loading = Task { [weak self] in
            let targets: [HintTarget] = switch kind {
            case .followLink: await index.links(in: regions).map(HintTarget.link)
            case .inverseSearch, .yankLine: await index.lines(in: regions).map(HintTarget.line)
            }
            guard let self, self.isActive, !Task.isCancelled else { return }
            guard !targets.isEmpty else {
                self.cancel()
                self.host?.hintsUnavailable(kind)
                return
            }
            let labels = HintLabels.make(targets.count)
            self.hints = Array(zip(labels, targets))
            self.render()
        }
    }

    /// Keys while hints are up. Returns true when the key was consumed (always, in hint mode).
    func feed(_ token: KeyToken) -> Bool {
        guard isActive else { return false }
        switch token {
        case "<Esc>":
            cancel()
        case "<BS>":
            typed = String(typed.dropLast())
            render()
        default:
            guard token.count == 1 else { cancel(); return true }
            typed += token.lowercased()
            let remaining = hints.filter { $0.label.hasPrefix(typed) }
            if remaining.count == 1, let choice = remaining.first, choice.label == typed {
                let kind = kind
                cancel()
                host?.hintChosen(choice.target, kind: kind)
            } else if remaining.isEmpty {
                NSSound.beep()
                cancel()
            } else {
                render()
            }
        }
        return true
    }

    var debugCount: Int { isActive ? hints.filter { $0.label.hasPrefix(typed) }.count : 0 }

    func cancel() {
        loading?.cancel()
        loading = nil
        isActive = false
        hints = []
        typed = ""
        overlay.clear()
    }

    private func render() {
        guard let host else { return }
        let visible = hints.filter { $0.label.hasPrefix(typed) }.map { hint -> HintOverlay.Badge in
            let rect = hint.target.rect
            let anchor: CGPoint = switch hint.target {
            case .link: CGPoint(x: rect.minX, y: rect.minY)
            // Just left of the line, so the label doesn't cover the text it labels.
            case .line: CGPoint(x: rect.minX, y: rect.midY)
            }
            let isLine = if case .line = hint.target { true } else { false }
            return HintOverlay.Badge(label: hint.label, typed: typed.count,
                                     point: host.overlayPoint(page: hint.target.page, point: anchor), leftOfPoint: isLine)
        }
        overlay.show(visible)
    }
}

/// Draws hint labels above the document, in screen space so they stay legible at any zoom.
@MainActor
final class HintOverlay: NSView {
    struct Badge {
        var label: String
        /// How many leading characters have been typed already (drawn dimmed).
        var typed: Int
        var point: CGPoint
        /// Place the badge to the left of `point` (vertically centred) instead of on it.
        var leftOfPoint: Bool
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ badges: [Badge]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clear()
        let scale = window?.backingScaleFactor ?? 2
        for badge in badges {
            let text = NSMutableAttributedString(string: badge.label.uppercased(), attributes: [
                .font: Self.font, .foregroundColor: NSColor.black,
            ])
            text.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.35),
                              range: NSRange(location: 0, length: min(badge.typed, badge.label.count)))
            let size = text.size()
            let frame = CGRect(
                x: badge.leftOfPoint ? badge.point.x - size.width - 10 : badge.point.x - 2,
                y: badge.leftOfPoint ? badge.point.y - (size.height + 2) / 2 : badge.point.y - 2,
                width: size.width + 6, height: size.height + 2)

            let layer = CATextLayer()
            layer.string = text
            layer.alignmentMode = .center
            layer.contentsScale = scale
            layer.frame = frame.integral
            layer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.95).cgColor
            layer.cornerRadius = 3
            layer.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
            layer.borderWidth = 0.5
            self.layer?.addSublayer(layer)
        }
        CATransaction.commit()
    }

    func clear() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }
}
