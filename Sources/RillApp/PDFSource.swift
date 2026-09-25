import CoreGraphics
import Foundation

/// An immutable snapshot of one PDF file, safe to render from any thread.
///
/// The file is read into memory once so a recompile that rewrites it mid-render can't
/// tear pages. Each render borrows a `CGPDFDocument` from a small pool, so several tiles
/// can render in parallel without sharing a document between threads.
final class PDFSource: @unchecked Sendable { // `pool` is guarded by `lock`; everything else is immutable
    let url: URL
    /// Displayed page sizes in points (crop box, after /Rotate).
    let pageSizes: [CGSize]

    private let data: Data
    private let lock = NSLock()
    private var pool: [CGPDFDocument] = []

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.url = url
        self.data = data
        self.pageSizes = (0..<document.numberOfPages).map { i in
            guard let page = document.page(at: i + 1) else { return CGSize(width: 612, height: 792) }
            let box = page.getBoxRect(.cropBox)
            return Self.isQuarterTurn(page) ? CGSize(width: box.height, height: box.width) : box.size
        }
        pool.append(document)
    }

    var pageCount: Int { pageSizes.count }

    /// Renders part of a page.
    /// - Parameters:
    ///   - pixelRect: the region in page pixels at `scale`, origin at the page's top-left.
    ///   - scale: pixels per point.
    func render(page index: Int, pixelRect: CGRect, scale: CGFloat) -> CGImage? {
        let width = Int(pixelRect.width.rounded(.up)), height = Int(pixelRect.height.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        let document = borrow()
        defer { giveBack(document) }
        guard let page = document.page(at: index + 1) else { return nil }

        // CG is y-up: shift so the requested (top-left-origin) rect lands in the bitmap.
        let pageHeightPixels = pageSizes[index].height * scale
        context.translateBy(x: -pixelRect.minX, y: -(pageHeightPixels - pixelRect.maxY))
        context.scaleBy(x: scale, y: scale)
        Self.applyRotation(of: page, to: context)
        let box = page.getBoxRect(.cropBox)
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: - Private

    private func borrow() -> CGPDFDocument {
        if let document = lock.withLock({ pool.popLast() }) { return document }
        let provider = CGDataProvider(data: data as CFData)!
        let document = CGPDFDocument(provider)!
        if document.isEncrypted { _ = document.unlockWithPassword("") }
        return document
    }

    private func giveBack(_ document: CGPDFDocument) {
        lock.withLock { pool.append(document) }
    }

    private static func normalizedRotation(_ page: CGPDFPage) -> Int32 {
        ((page.rotationAngle % 360) + 360) % 360
    }

    private static func isQuarterTurn(_ page: CGPDFPage) -> Bool {
        let r = normalizedRotation(page)
        return r == 90 || r == 270
    }

    /// Maps crop-box coordinates to upright display coordinates (points, y-up, origin 0).
    /// /Rotate is a clockwise rotation of the page when displayed.
    private static func applyRotation(of page: CGPDFPage, to context: CGContext) {
        let box = page.getBoxRect(.cropBox)
        switch normalizedRotation(page) {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
    }
}
