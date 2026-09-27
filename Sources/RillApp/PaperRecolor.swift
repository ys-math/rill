import CoreGraphics
import CoreImage
import RillCore

/// Dark mode for pages: "dark paper" rather than a plain invert. Lightness is inverted but hue
/// is kept, so coloured figures and links stay recognisable, and the range is compressed so
/// paper becomes `paper` and text `ink` (by default dark and light grey) instead of pure black
/// and white.
struct PaperRecolor: Equatable, Sendable {
    /// Paper and ink after recolouring (sRGB).
    let paper: RGBColor
    let ink: RGBColor

    var paperColor: CGColor { CGColor(srgbRed: paper.red, green: paper.green, blue: paper.blue, alpha: 1) }

    /// Shared, thread-safe. Works in sRGB (not linear) so inversion looks even to the eye.
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    func apply(_ image: CGImage) -> CGImage? {
        let recoloured = CIImage(cgImage: image)
            .applyingFilter("CIColorInvert")
            // Inverting also flips hue; turning it half way round puts it back.
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
            // Each channel maps 0…1 to paper…ink.
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: ink.red - paper.red, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: ink.green - paper.green, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: ink.blue - paper.blue, w: 0),
                "inputBiasVector": CIVector(x: paper.red, y: paper.green, z: paper.blue, w: 0),
            ])
        return Self.context.createCGImage(recoloured, from: recoloured.extent, format: .BGRA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
