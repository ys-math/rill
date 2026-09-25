import AppKit
import QuartzCore

/// `g!`: frame-rate overlay. Counts display-link callbacks on the main thread, so it catches
/// main-thread hitches (the usual cause of dropped frames). Instruments remains the ground truth.
@MainActor
final class FrameHUD: NSView {
    private let label = NSTextField(labelWithString: "")
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var worst: CFTimeInterval = 0
    private var drops = 0
    private var totalDrops = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func toggle() {
        isHidden.toggle()
        if isHidden {
            link?.invalidate()
            link = nil
        } else {
            last = nil
            totalDrops = 0
            label.stringValue = "— fps"
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let nominal = link.targetTimestamp - link.timestamp
        defer { last = now }
        guard let last else { windowStart = now; return }
        let interval = now - last
        frames += 1
        worst = max(worst, interval)
        if interval > nominal * 1.5 { drops += 1; totalDrops += 1 }
        if now - windowStart >= 1 {
            let fps = Double(frames) / (now - windowStart)
            label.stringValue = String(format: "%3.0f fps  worst %4.1f ms  drops %d (total %d)",
                                       fps, worst * 1000, drops, totalDrops)
            frames = 0
            worst = 0
            drops = 0
            windowStart = now
        }
    }
}
