import CoreGraphics
import CoreImage

/// Dark mode for pages: "dark paper" rather than a plain invert. Lightness is inverted but hue
/// is kept, so coloured figures and links stay recognisable, and the range is compressed so
/// paper becomes dark grey and text light grey instead of pure black and white.
enum PaperRecolor {
    /// Paper and ink after recolouring (sRGB gray levels).
    static let paper: CGFloat = 0.14
    static let ink: CGFloat = 0.86

    static let paperColor = CGColor(gray: paper, alpha: 1)

    /// Shared, thread-safe. Works in sRGB (not linear) so inversion looks even to the eye.
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    static func apply(_ image: CGImage) -> CGImage? {
        let scale = ink - paper
        let recoloured = CIImage(cgImage: image)
            .applyingFilter("CIColorInvert")
            // Inverting also flips hue; turning it half way round puts it back.
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputBiasVector": CIVector(x: paper, y: paper, z: paper, w: 0),
            ])
        return context.createCGImage(recoloured, from: recoloured.extent, format: .BGRA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
