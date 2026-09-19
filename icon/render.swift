// Renders the source plates the icon is moshed from.
// AppKit rather than ffmpeg's drawtext, which this build has no freetype for —
// and it gets Menlo at the wordmark's own tracking, which is the point.
import AppKit
import Foundation

let size = 1024

func image(_ draw: (CGContext, NSSize) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext, NSSize(width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let paper = NSColor(srgbRed: 0.941, green: 0.925, blue: 0.886, alpha: 1)
let ink   = NSColor(srgbRed: 0.102, green: 0.102, blue: 0.090, alpha: 1)
let coral = NSColor(srgbRed: 0.929, green: 0.506, blue: 0.349, alpha: 1)
let teal  = NSColor(srgbRed: 0.322, green: 0.690, blue: 0.643, alpha: 1)
let steel = NSColor(srgbRed: 0.310, green: 0.494, blue: 0.659, alpha: 1)
let violet = NSColor(srgbRed: 0.420, green: 0.357, blue: 0.769, alpha: 1)
let amber = NSColor(srgbRed: 0.753, green: 0.553, blue: 0.086, alpha: 1)
let lilac = NSColor(srgbRed: 0.827, green: 0.655, blue: 0.863, alpha: 1)

// Plate A — the letterform. These are the pixels the mosh will drag.
let plateA = image { _, s in
    paper.setFill(); NSRect(origin: .zero, size: s).fill()
    let font = NSFont(name: "Menlo-Bold", size: 720) ?? .boldSystemFont(ofSize: 720)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: ink, .kern: 0,
    ]
    let str = NSAttributedString(string: "B", attributes: attrs)
    let bounds = str.boundingRect(with: s, options: [.usesLineFragmentOrigin])
    str.draw(at: NSPoint(x: (s.width - bounds.width) / 2,
                         y: (s.height - bounds.height) / 2 - 20))
}
write(plateA, "icon/work/plate_a.png")

// Plate B — hard-edged bands carrying the whole Signal palette. Nothing here
// survives into the icon as itself; it exists to supply motion vectors with a
// strong, coherent direction for the bloom to drag the letter with, and its
// colours are what bleed into the tears. More bands, thinner, means more of the
// palette ends up in the letter.
let plateB = image { _, s in
    paper.setFill(); NSRect(origin: .zero, size: s).fill()
    let colors = [coral, teal, steel, violet, amber, lilac, ink, coral, steel, teal, violet, amber]
    let heights: [CGFloat] = [46, 78, 30, 62, 94, 38, 24, 70, 52, 86, 34, 58]
    var y: CGFloat = 0
    var i = 0
    while y < s.height {
        colors[i % colors.count].setFill()
        NSRect(x: 0, y: y, width: s.width, height: heights[i % heights.count]).fill()
        y += heights[i % heights.count]
        i += 1
    }
}
write(plateB, "icon/work/plate_b.png")
