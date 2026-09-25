import CoreGraphics

/// Converts between PDF page space (points, origin bottom-left of the media box, before
/// /Rotate) and rill's display space (points, origin top-left of the crop box, after /Rotate).
public struct PageGeometry: Equatable, Sendable {
    public let cropBox: CGRect
    /// Clockwise, normalized to 0, 90, 180 or 270.
    public let rotation: Int

    public init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox
        self.rotation = ((rotation % 360) + 360) % 360
    }

    public var displaySize: CGSize {
        rotation == 90 || rotation == 270 ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size
    }

    public func displayPoint(_ p: CGPoint) -> CGPoint {
        let u = p.x - cropBox.minX, v = p.y - cropBox.minY
        let w = cropBox.width, h = cropBox.height
        // Upright, y-up coordinates after rotating the page clockwise.
        let (x, yUp): (CGFloat, CGFloat) = switch rotation {
        case 90: (v, w - u)
        case 180: (w - u, h - v)
        case 270: (h - v, u)
        default: (u, v)
        }
        return CGPoint(x: x, y: displaySize.height - yUp)
    }

    public func displayRect(_ r: CGRect) -> CGRect {
        let a = displayPoint(CGPoint(x: r.minX, y: r.minY))
        let b = displayPoint(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The inverse of `displayPoint`.
    public func pagePoint(_ d: CGPoint) -> CGPoint {
        let w = cropBox.width, h = cropBox.height
        let x = d.x, yUp = displaySize.height - d.y
        let (u, v): (CGFloat, CGFloat) = switch rotation {
        case 90: (w - yUp, x)
        case 180: (w - x, h - yUp)
        case 270: (yUp, h - x)
        default: (x, yUp)
        }
        return CGPoint(x: u + cropBox.minX, y: v + cropBox.minY)
    }
}
