import CoreGraphics

/// Auto-trim: cut away the white margins around the text.
///
/// Every page of the same size and parity gets the same trim (the union of their content),
/// so the text block doesn't shift or resize from page to page, and a two-sided document's
/// odd and even pages each lose their own gutter.
public struct TrimProfile: Equatable, Sendable {
    struct Group: Hashable {
        var width: Int
        var height: Int
        var odd: Bool

        init(page index: Int, size: CGSize) {
            width = Int(size.width.rounded())
            height = Int(size.height.rounded())
            odd = index % 2 == 1
        }
    }

    var trims: [Group: CGRect]

    /// - Parameters:
    ///   - contentBoxes: each page's content in page display coordinates; nil for a blank page.
    ///   - padding: white space kept around the content, in points.
    public init(contentBoxes: [CGRect?], pageSizes: [CGSize], padding: CGFloat = 10) {
        var trims: [Group: CGRect] = [:]
        for (index, box) in contentBoxes.enumerated() where index < pageSizes.count {
            guard let box, !box.isEmpty else { continue }
            let group = Group(page: index, size: pageSizes[index])
            trims[group] = trims[group].map { $0.union(box) } ?? box
        }
        for (group, content) in trims {
            let page = CGRect(x: 0, y: 0, width: group.width, height: group.height)
            trims[group] = content.insetBy(dx: -padding, dy: -padding).intersection(page).integral
        }
        self.trims = trims
    }

    /// The part of each page to show. Pages in a group with no content show whole.
    public func trims(for pageSizes: [CGSize]) -> [CGRect] {
        pageSizes.enumerated().map { index, size in
            trims[Group(page: index, size: size)] ?? CGRect(origin: .zero, size: size)
        }
    }
}

public enum ContentBounds {
    /// The bounding box, in pixels (origin top-left), of every pixel darker than `threshold`
    /// in an 8-bit bitmap. Only the first three channels of each pixel are looked at, so
    /// alpha is ignored. Nil when the bitmap is blank.
    public static func find(in bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                            bytesPerPixel: Int, threshold: UInt8 = 240) -> CGRect? {
        let channels = min(bytesPerPixel, 3)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * bytesPerRow
            var x = 0
            while x < width {
                let p = row + x * bytesPerPixel
                var ink = false
                for c in 0..<channels where bytes[p + c] < threshold { ink = true }
                if ink {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = y
                    // Everything between here and the rightmost ink so far can't widen the box.
                    if x < maxX { x = maxX }
                }
                x += 1
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
