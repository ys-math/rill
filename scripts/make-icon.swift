// Draws the Rill app icon and writes Resources/Rill.icns.
//
// The icon is a sheet of paper on a deep blue squircle, with a display-size integral sign
// running down the page like a small stream: a rill, and the maths it's there to show.
//
// Run with `make icon`.

import AppKit
import CoreText

let outputICNS = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Resources/Rill.icns")
let integralFont = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/STIXIntDBol.otf")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func linearGradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: colors as CFArray, locations: nil)!
}

/// The integral glyph's outline, scaled and centred on `center` with the given height.
func integralPath(center: CGPoint, height: CGFloat) -> CGPath {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(integralFont as CFURL)
            as? [CTFontDescriptor], let descriptor = descriptors.first else {
        fatalError("can't load \(integralFont.path)")
    }
    let font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
    var character: UniChar = 0x222B  // ∫
    var glyph: CGGlyph = 0
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
          let raw = CTFontCreatePathForGlyph(font, glyph, nil) else {
        fatalError("no ∫ glyph in \(integralFont.lastPathComponent)")
    }
    let box = raw.boundingBoxOfPath
    let scale = height / box.height
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -box.midX, y: -box.midY)
    return raw.copy(using: &transform)!
}

/// Draws the icon on the 1024-point macOS icon grid, for output `pixels` wide.
func drawIcon(in ctx: CGContext, pixels: Int) {
    // Background squircle: the standard 824-point body with a 100-point margin.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x13294B))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.drawLinearGradient(linearGradient([color(0x2F6FC0), color(0x14306A), color(0x0B1B3D)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100),
                           options: [])
    ctx.restoreGState()

    // The page, with a folded top-right corner.
    let page = CGRect(x: 262, y: 188, width: 500, height: 648)
    let fold: CGFloat = 120
    let pagePath = CGMutablePath()
    pagePath.move(to: CGPoint(x: page.minX, y: page.minY))
    pagePath.addLine(to: CGPoint(x: page.maxX, y: page.minY))
    pagePath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    pagePath.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    pagePath.addLine(to: CGPoint(x: page.minX, y: page.maxY))
    pagePath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.45))
    ctx.addPath(pagePath)
    ctx.setFillColor(color(0xFBFAF6))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(pagePath)
    ctx.clip()
    ctx.drawLinearGradient(linearGradient([color(0xFFFFFF), color(0xECEAE3)]),
                           start: CGPoint(x: 512, y: page.maxY), end: CGPoint(x: 512, y: page.minY),
                           options: [])
    ctx.restoreGState()

    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    foldPath.addLine(to: CGPoint(x: page.maxX - fold + 8, y: page.maxY - fold + 8))
    foldPath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    foldPath.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -4, height: -4), blur: 10, color: color(0x000000, 0.25))
    ctx.addPath(foldPath)
    ctx.setFillColor(color(0xD9D6CC))
    ctx.fillPath()
    ctx.restoreGState()

    // The integral, filled with a water-blue gradient running down the page.
    // At small sizes, grow the glyph by its own outline so its hairline ends don't vanish.
    let glyph = integralPath(center: CGPoint(x: 492, y: 492), height: 500)
    let growth: CGFloat = pixels <= 64 ? 22 : pixels <= 128 ? 10 : 0
    let integral = growth == 0 ? glyph
        : glyph.union(glyph.copy(strokingWithWidth: growth, lineCap: .round,
                                 lineJoin: .round, miterLimit: 10))
    ctx.saveGState()
    ctx.addPath(integral)
    ctx.clip()
    let bounds = integral.boundingBoxOfPath
    ctx.drawLinearGradient(linearGradient([color(0x3FC1E8), color(0x1F6FD1), color(0x173E9A)]),
                           start: CGPoint(x: bounds.maxX, y: bounds.maxY),
                           end: CGPoint(x: bounds.minX, y: bounds.minY),
                           options: [])
    ctx.restoreGState()
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx, pixels: pixels)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Rill-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try renderPNG(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputICNS.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(outputICNS.path)")
