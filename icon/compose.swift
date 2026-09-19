// Builds the .iconset from the moshed plates.
//
// The art is not a glitch filter — it is a frame of real datamoshed video,
// produced by running a letterform through Beygla's own engine and pulling a
// frame out a few past the bloom.
//
// The art is drawn full-bleed. Current macOS masks an app icon to the system
// shape itself and fills whatever the icon leaves transparent, so an inset tile
// on the old Big Sur grid comes back sitting on a grey plate — which is exactly
// what happened on the first pass. Handing over edge-to-edge art lets the paper
// fill the shape and leaves the corner treatment to the OS, which also settles
// the square-versus-squircle question: the art keeps the system's square
// corners and the platform rounds them if that is what it does this year.
import AppKit
import Foundation

let work = "icon/work"
let out = "icon/Beygla.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func load(_ name: String) -> CGImage {
    let d = NSData(contentsOfFile: "\(work)/\(name)")!
    return NSBitmapImageRep(data: d as Data)!.cgImage!
}

let moshed = load("f11.png")     // most torn that still reads as a letter
let torn = load("f10.png")       // calmer — for the middle sizes
let plain = load("plate_a.png")  // the untouched letterform

let paper = NSColor(srgbRed: 0.941, green: 0.925, blue: 0.886, alpha: 1)
let ink = NSColor(srgbRed: 0.102, green: 0.102, blue: 0.090, alpha: 1)
let coral = NSColor(srgbRed: 0.929, green: 0.506, blue: 0.349, alpha: 1)
let teal = NSColor(srgbRed: 0.322, green: 0.690, blue: 0.643, alpha: 1)
let steel = NSColor(srgbRed: 0.310, green: 0.494, blue: 0.659, alpha: 1)
let violet = NSColor(srgbRed: 0.420, green: 0.357, blue: 0.769, alpha: 1)
let amber = NSColor(srgbRed: 0.753, green: 0.553, blue: 0.086, alpha: 1)

/// The letterform sits slightly below centre in the plate; crop around it so it
/// fills the tile rather than floating in it.
let cropRect = CGRect(x: 0, y: 26, width: 1024, height: 1024 - 26)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 32)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    ctx.interpolationQuality = .high

    let s = CGFloat(size)
    let tile = CGRect(x: 0, y: 0, width: s, height: s)

    ctx.setFillColor(paper.cgColor)
    ctx.fill(tile)

    ctx.saveGState()
    ctx.clip(to: tile)

    if size >= 128 {
        // Large enough to carry the real mosh.
        let source = size >= 512 ? moshed : torn
        if let cropped = source.cropping(to: cropRect) {
            ctx.draw(cropped, in: tile)
        }
    } else {
        // Below 128 a downscaled 820px plate turns to mush: the strokes blur
        // and the torn bands collapse into noise. The small sizes get the
        // letterform set as live type at the target size, which stays crisp,
        // with a couple of clean tears standing in for the mosh.
        // Size and place the glyph by its own path bounds. An attributed
        // string's size() includes ascent, descent and leading, so centring on
        // that pushes a capital letter below the tile and overflows it.
        func fitted(_ target: CGFloat) -> (CTLine, CGRect) {
            func line(_ pt: CGFloat) -> CTLine {
                let f = NSFont(name: "Menlo-Bold", size: pt) ?? .boldSystemFont(ofSize: pt)
                return CTLineCreateWithAttributedString(
                    NSAttributedString(string: "B", attributes: [.font: f, .foregroundColor: ink]))
            }
            let probe = CTLineGetBoundsWithOptions(line(100), .useGlyphPathBounds)
            let pt = 100 * target / probe.height
            let final = line(pt)
            return (final, CTLineGetBoundsWithOptions(final, .useGlyphPathBounds))
        }

        // Keep the letter clear of the corners the system mask rounds off.
        let (line, gb) = fitted(tile.height * 0.58)
        let origin = CGPoint(x: tile.midX - (gb.minX + gb.width / 2),
                             y: tile.midY - (gb.minY + gb.height / 2))

        func drawGlyph(dx: CGFloat) {
            ctx.textPosition = CGPoint(x: origin.x + dx, y: origin.y)
            CTLineDraw(line, ctx)
        }
        drawGlyph(dx: 0)

        // Both the number of tears and how far they slip come down with the
        // tile. Displacement that reads as a torn macroblock row at 64px just
        // breaks the letter into unrecognisable pieces at 16, and an icon that
        // cannot be identified in the Dock has failed at its only job.
        let bands: [(CGFloat, CGFloat, NSColor, CGFloat)]
        switch size {
        case ...16:
            bands = [(0.52, 0.10, coral, 0)]
        case ...32:
            bands = [(0.34, 0.075, teal, 0.030), (0.58, 0.085, coral, -0.026)]
        default:
            bands = [(0.24, 0.045, violet, 0.026), (0.36, 0.050, steel, -0.030),
                     (0.48, 0.070, coral, 0.042), (0.62, 0.042, amber, 0.022),
                     (0.72, 0.055, teal, -0.028)]
        }

        for (yFrac, hFrac, color, shift) in bands {
            let band = CGRect(x: tile.minX, y: tile.minY + yFrac * tile.height,
                              width: tile.width, height: max(1, hFrac * tile.height))
            ctx.saveGState()
            ctx.clip(to: band)
            ctx.setFillColor(paper.cgColor)
            ctx.fill(band)
            drawGlyph(dx: shift * tile.width)   // the row, torn sideways
            ctx.restoreGState()

            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: band.minX, y: band.minY,
                            width: band.width, height: max(1, band.height * 0.5)))
        }
    }

    ctx.restoreGState()

    // No border: a hairline drawn at the canvas edge is cropped away by the
    // system mask, and what survives reads as a stray arc in the corners.

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(Int, [String])] = [
    (16,   ["icon_16x16.png"]),
    (32,   ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64,   ["icon_32x32@2x.png"]),
    (128,  ["icon_128x128.png"]),
    (256,  ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512,  ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

for (size, names) in entries {
    let data = render(size: size)
    for n in names {
        try! data.write(to: URL(fileURLWithPath: "\(out)/\(n)"))
    }
    print("rendered \(size)px -> \(names.joined(separator: ", "))")
}

// A flat PNG for the readme and the site.
try! render(size: 1024).write(to: URL(fileURLWithPath: "icon/beygla-icon.png"))
print("wrote icon/beygla-icon.png")
