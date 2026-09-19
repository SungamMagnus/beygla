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

// Plate B — hard-edged bands in the signal palette. Nothing here survives into
// the icon; it exists only to supply motion vectors with a strong, coherent
// direction for the bloom to drag the letter with.
let plateB = image { _, s in
    paper.setFill(); NSRect(origin: .zero, size: s).fill()
    let colors = [coral, teal, steel, ink, coral, teal]
    var y: CGFloat = 0
    var i = 0
    while y < s.height {
        let h = CGFloat([70, 130, 44, 96, 160, 58][i % 6])
        colors[i % colors.count].setFill()
        NSRect(x: 0, y: y, width: s.width, height: h).fill()
        y += h
        i += 1
    }
}
write(plateB, "icon/work/plate_b.png")
