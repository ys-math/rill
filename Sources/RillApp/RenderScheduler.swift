import CoreGraphics
import Foundation
import RillCore

enum RenderRequest: Hashable {
    case tile(TileKey)
    /// A whole page at `DocumentView.thumbnailScale`, shown while tiles render.
    case thumbnail(page: Int)
}

/// Renders requests on background threads and delivers images on the main actor.
/// Only what's currently wanted stays queued; everything else is cancelled.
@MainActor
final class RenderScheduler {
    enum Priority { case visible, prefetch }

    private let source: PDFSource
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "rill.render"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = max(2, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4))
        return q
    }()
    private var inFlight: [RenderRequest: Operation] = [:]
    private let deliver: @MainActor (RenderRequest, CGImage) -> Void

    init(source: PDFSource, deliver: @escaping @MainActor (RenderRequest, CGImage) -> Void) {
        self.source = source
        self.deliver = deliver
    }

    func isPending(_ request: RenderRequest) -> Bool { inFlight[request] != nil }

    /// Queues everything in `wanted` that isn't already queued, and cancels queued work not in it
    /// (except tiles, when `retainingTiles`).
    func update(wanted: [RenderRequest: Priority], retainingTiles: Bool = false) {
        for (request, op) in inFlight where wanted[request] == nil {
            if retainingTiles, case .tile = request { continue }
            op.cancel()
            inFlight[request] = nil
        }
        for (request, priority) in wanted {
            if let op = inFlight[request] {
                op.queuePriority = Self.queuePriority(request, priority)
                continue
            }
            enqueue(request, priority: priority)
        }
    }

    /// Renders synchronously on the calling thread. For the rare case where showing
    /// nothing for a frame is worse than a few ms of main-thread work.
    func renderNow(_ request: RenderRequest) -> CGImage? {
        Self.render(request, source: source)
    }

    func cancelAll() {
        queue.cancelAllOperations()
        inFlight.removeAll()
    }

    private func enqueue(_ request: RenderRequest, priority: Priority) {
        let source = source
        let op = BlockOperation()
        op.addExecutionBlock { [weak op] in
            guard let op, !op.isCancelled, let image = Self.render(request, source: source) else { return }
            let box = UncheckedImage(image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, !op.isCancelled, self.inFlight[request] === op else { return }
                    self.inFlight[request] = nil
                    self.deliver(request, box.image)
                }
            }
        }
        op.queuePriority = Self.queuePriority(request, priority)
        inFlight[request] = op
        queue.addOperation(op)
    }

    private static func queuePriority(_ request: RenderRequest, _ priority: Priority) -> Operation.QueuePriority {
        switch (request, priority) {
        case (.thumbnail, .visible): .veryHigh
        case (.tile, .visible): .high
        case (.thumbnail, .prefetch): .normal
        case (.tile, .prefetch): .low
        }
    }

    nonisolated private static func render(_ request: RenderRequest, source: PDFSource) -> CGImage? {
        switch request {
        case .thumbnail(let page):
            let scale = DocumentView.thumbnailScale
            let size = source.pageSizes[page]
            return source.render(page: page, pixelRect: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale),
                                 scale: scale)
        case .tile(let key):
            let scale = TileGrid.scale(forLevel: key.level)
            let rect = TileGrid.rect(of: key, pageSize: source.pageSizes[key.page])
            let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            return source.render(page: key.page, pixelRect: pixels, scale: scale)
        }
    }
}

/// CGImage is immutable and thread-safe; this carries one across the queue hop.
private struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
