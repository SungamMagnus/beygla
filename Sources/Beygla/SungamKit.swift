import AppKit
import SwiftUI

// The Sungam design system, ported to SwiftUI.
//
// Rules carried over verbatim from the system: colour is signal and never
// decoration, backgrounds are flat paper, type is one monospace face at every
// size, there are no shadows and no icons, corners are square, and borders are
// hairlines drawn at partial ink opacity rather than in a separate grey.
//
// Panel tokens are sized for a plug-in window where a control label sits around
// 9px. A desktop window is a bigger surface, so the same ratios are scaled up by
// `Sungam.scale` — the system's own instruction, rather than a second type ramp.

enum Sungam {
    static let scale: CGFloat = 1.25

    // MARK: Base

    static let paper = Color(red: 0.941, green: 0.925, blue: 0.886)   // #f0ece2
    static let ink = Color(red: 0.102, green: 0.102, blue: 0.090)     // #1a1a17

    static func ink(_ alpha: Double) -> Color { ink.opacity(alpha) }

    static let ink08 = ink(0.08), ink13 = ink(0.13), ink18 = ink(0.18)
    static let ink22 = ink(0.22), ink28 = ink(0.28), ink32 = ink(0.32)
    static let ink38 = ink(0.38), ink45 = ink(0.45), ink55 = ink(0.55)
    static let ink62 = ink(0.62), ink70 = ink(0.70), ink85 = ink(0.85)

    // MARK: Signal palette
    //
    // Beygla's assignment, held to consistently the way each Sungam product
    // holds to its own:
    //
    //   coral   the trigger path — everything that decides *when*
    //   teal    the effect engine — everything that decides *what*
    //   steel   the render chain — everything after the ops are applied
    //   violet  modulation only — the parameters that move another parameter
    //   amber   the live state, and nothing else
    //   lilac   trims subordinate to the control they hang off

    static let coral = Color(red: 0.929, green: 0.506, blue: 0.349)   // #ed8159
    static let teal = Color(red: 0.322, green: 0.690, blue: 0.643)    // #52b0a4
    static let steel = Color(red: 0.310, green: 0.494, blue: 0.659)   // #4f7ea8
    static let violet = Color(red: 0.420, green: 0.357, blue: 0.769)  // #6b5bc4
    static let amber = Color(red: 0.753, green: 0.553, blue: 0.086)   // #c08d16
    static let lilac = Color(red: 0.827, green: 0.655, blue: 0.863)   // #d3a7dc
    static let lilacText = Color(red: 0.604, green: 0.388, blue: 0.671)

    // MARK: Type
    //
    // Menlo is what JUCE's getDefaultMonospacedFontName() returns on macOS, so
    // the app is set in the same face the plug-in panels are.

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Menlo", size: size * scale).weight(weight)
    }

    static let text2xs: CGFloat = 7.5
    static let textXs: CGFloat = 8
    static let textSm: CGFloat = 8.5
    static let textBase: CGFloat = 9.5
    static let textMd: CGFloat = 10.5
    static let textLg: CGFloat = 13
    static let textXl: CGFloat = 16

    static let trackingWordmark = 0.28
    static let trackingWide = 0.05

    // MARK: Geometry

    static let hairline: CGFloat = 1
    static let borderDefault: CGFloat = 1.2
    static let borderStrong: CGFloat = 1.4

    /// 317.2° of pot travel, leaving a gap at the bottom where the pointer
    /// never goes. Half-sweep, in radians.
    static let knobHalfSweep = 158.6 * .pi / 180.0
}

// MARK: - Wordmark

/// Letter-spaced caps. Used for the product name and for section captions
/// alike — there is no second treatment.
struct Wordmark: View {
    let text: String
    var size: CGFloat = Sungam.textXl
    var color: Color = Sungam.ink55

    var body: some View {
        Text(text.uppercased())
            .font(Sungam.mono(size, weight: .bold))
            .tracking(size * Sungam.scale * Sungam.trackingWordmark)
            .foregroundStyle(color)
    }
}

// MARK: - PanelFrame

/// A section drawn as the box its controls sit inside: a hairline rule in the
/// section colour, with the title inset into the rule rather than captioned
/// above it.
struct PanelFrame<Content: View>: View {
    let title: String
    var color: Color = Sungam.coral
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .stroke(color, lineWidth: Sungam.hairline)
                    .overlay(alignment: .topLeading) {
                        Text(title.uppercased())
                            .font(Sungam.mono(Sungam.textSm))
                            .tracking(Sungam.textSm * Sungam.scale * 0.04)
                            .foregroundStyle(color)
                            .padding(.horizontal, 6)
                            .background(Sungam.paper)
                            .padding(.leading, 14)
                            .offset(y: -Sungam.textSm * Sungam.scale * 0.62)
                    }
            }
    }
}

// MARK: - Knob

/// One circle, one arc, one pointer. Unipolar knobs grow the arc from the
/// anticlockwise stop, bipolar ones from noon. Drag vertically to turn it;
/// hold shift for a finer drag.
struct Knob: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0 ... 1
    var radius: CGFloat = 20
    var color: Color = Sungam.coral
    var bipolar: Bool = false
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    @State private var dragStart: Double?

    private var norm: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var r: CGFloat { radius * Sungam.scale }
    private var labelSize: CGFloat { radius >= 30 ? 10 : radius >= 18 ? 9 : 8 }

    var body: some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(Sungam.mono(labelSize))
                .tracking(labelSize * Sungam.scale * 0.02)
                .foregroundStyle(Sungam.ink62)
            Text(format(value))
                .font(Sungam.mono(labelSize + 2, weight: .bold))
                .foregroundStyle(color)

            Canvas { ctx, size in draw(ctx, size: size) }
                .frame(width: r * 2 + 18, height: r * 2 + 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let fine = NSEvent.modifierFlags.contains(.shift)
                            turn(g, gain: fine ? 0.0012 : 0.006)
                        }
                        .onEnded { _ in dragStart = nil }
                )
        }
    }

    private func turn(_ g: DragGesture.Value, gain: Double) {
        let base = dragStart ?? norm
        if dragStart == nil { dragStart = norm }
        let next = min(max(base - Double(g.translation.height) * gain, 0), 1)
        value = range.lowerBound + next * (range.upperBound - range.lowerBound)
    }

    private func angle(_ n: Double) -> Double {
        -Sungam.knobHalfSweep + 2 * Sungam.knobHalfSweep * min(max(n, 0), 1) - .pi / 2
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let aStart = angle(0), aEnd = angle(1), aNow = angle(norm)
        let track = r + 4.5
        let w: CGFloat = radius >= 24 ? 3.4 : radius >= 16 ? 2.8 : 2.2

        // Body
        let body = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.fill(body, with: .color(Sungam.paper))
        ctx.stroke(body, with: .color(Sungam.ink38), lineWidth: Sungam.borderDefault)

        // Unlit track, then the lit arc
        ctx.stroke(arc(c, track, aStart, aEnd), with: .color(Sungam.ink13), lineWidth: w)
        let from = bipolar ? -Double.pi / 2 : aStart
        ctx.stroke(arc(c, track, from, aNow), with: .color(color), lineWidth: w)

        // Pointer
        var pointer = Path()
        pointer.move(to: point(c, r * 0.16, aNow))
        pointer.addLine(to: point(c, r * 0.78, aNow))
        ctx.stroke(pointer, with: .color(Sungam.ink85), lineWidth: radius >= 24 ? 2 : 1.5)

        // The tick at the anticlockwise stop
        var tick = Path()
        tick.move(to: point(c, r + 1.5, aStart))
        tick.addLine(to: point(c, r + 6.5, aStart))
        ctx.stroke(tick, with: .color(Sungam.ink28), lineWidth: 1)
    }

    private func point(_ c: CGPoint, _ radius: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a)))
    }

    private func arc(_ c: CGPoint, _ radius: CGFloat, _ a: Double, _ b: Double) -> Path {
        var p = Path()
        guard abs(b - a) > 1e-4 else { return p }
        p.addArc(center: c, radius: radius,
                 startAngle: .radians(min(a, b)), endAngle: .radians(max(a, b)),
                 clockwise: false)
        return p
    }
}

// MARK: - Latch

/// The panel's toggle: filled and coloured when on, an outline of the same
/// colour when off. No pill switches, no checkmarks.
struct Latch: View {
    let label: String
    @Binding var on: Bool
    var color: Color = Sungam.amber
    var width: CGFloat? = nil

    var body: some View {
        Text(label.uppercased())
            .font(Sungam.mono(Sungam.textXs))
            .tracking(Sungam.textXs * Sungam.scale * 0.02)
            .foregroundStyle(on ? Sungam.paper : Sungam.ink62)
            .frame(width: width.map { $0 * Sungam.scale }, height: 17 * Sungam.scale)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .padding(.horizontal, width == nil ? 0 : 0)
            .background(on ? color : Sungam.paper)
            .overlay(Rectangle().stroke(on ? color : Sungam.ink28,
                                        lineWidth: Sungam.borderDefault))
            .contentShape(Rectangle())
            .onTapGesture { on.toggle() }
    }
}

/// A latch that fires an action instead of holding state — same treatment, so
/// the panel keeps one button vocabulary.
struct LatchButton: View {
    let label: String
    var color: Color = Sungam.ink62
    var filled: Bool = false
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Text(label.uppercased())
            .font(Sungam.mono(Sungam.textXs))
            .tracking(Sungam.textXs * Sungam.scale * 0.02)
            .foregroundStyle(filled ? Sungam.paper : (enabled ? Sungam.ink62 : Sungam.ink28))
            .padding(.horizontal, 10)
            .frame(height: 17 * Sungam.scale)
            .background(filled ? color : Sungam.paper)
            .overlay(Rectangle().stroke(filled ? color : (enabled ? Sungam.ink28 : Sungam.ink13),
                                        lineWidth: Sungam.borderDefault))
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .opacity(enabled ? 1 : 0.6)
    }
}

// MARK: - Selector

/// N-position selector. Every position stays labelled — nothing is abbreviated
/// to fit.
struct Selector<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var color: Color = Sungam.teal
    var vertical: Bool = false
    /// A position that cannot be chosen yet recedes to tertiary ink rather than
    /// disappearing — the panel keeps its shape.
    var isEnabled: (T) -> Bool = { _ in true }

    var body: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))

        layout {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                let active = opt.value == selection
                let on = isEnabled(opt.value)
                Text(opt.label.uppercased())
                    .font(Sungam.mono(Sungam.textBase))
                    .tracking(Sungam.textBase * Sungam.scale * 0.02)
                    .foregroundStyle(active ? Sungam.paper : (on ? Sungam.ink62 : Sungam.ink28))
                    .padding(.vertical, 5)
                    .padding(.horizontal, vertical ? 8 : 4)
                    .frame(maxWidth: .infinity)
                    .background(active ? color : Color.clear)
                    .opacity(on ? 1 : 0.7)
                    .overlay(alignment: vertical ? .bottom : .trailing) {
                        if i < options.count - 1 {
                            Rectangle()
                                .fill(Sungam.ink18)
                                .frame(width: vertical ? nil : Sungam.hairline,
                                       height: vertical ? Sungam.hairline : nil)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if on { selection = opt.value } }
            }
        }
        .overlay(Rectangle().stroke(Sungam.ink28, lineWidth: Sungam.hairline))
    }
}

// MARK: - Lamp

/// Lit when something is happening, outlined when it is not. Never a coloured
/// dot — always a small square.
struct Lamp: View {
    var on: Bool
    var color: Color = Sungam.ink
    var size: CGFloat = 9

    var body: some View {
        Rectangle()
            .fill(on ? color : Sungam.paper)
            .frame(width: size * Sungam.scale, height: size * Sungam.scale)
            .overlay(Rectangle().stroke(on ? Color.clear : color.opacity(0.45),
                                        lineWidth: Sungam.hairline))
    }
}

// MARK: - SegmentMeter

/// A level meter filling in discrete segments. The last segment reads amber
/// regardless of section colour — it means you are nearly out of room.
struct SegmentMeter: View {
    var level: Double
    var color: Color = Sungam.steel
    var segments: Int = 12
    var horizontal: Bool = true

    var body: some View {
        let lit = Int((min(max(level, 0), 1) * Double(segments)).rounded())
        let layout = horizontal
            ? AnyLayout(HStackLayout(spacing: 3))
            : AnyLayout(VStackLayout(spacing: 3))

        layout {
            ForEach(0 ..< segments, id: \.self) { i in
                let index = horizontal ? i : segments - 1 - i
                let on = index < lit
                let isLast = index == segments - 1
                Rectangle()
                    .fill(on ? (isLast ? Sungam.amber : color) : Sungam.paper)
                    .overlay(Rectangle().stroke(on ? Color.clear : Sungam.ink22,
                                                lineWidth: Sungam.hairline))
                    .frame(width: horizontal ? nil : 16 * Sungam.scale,
                           height: horizontal ? 6 * Sungam.scale : 6 * Sungam.scale)
            }
        }
    }
}

// MARK: - Label / value pair

/// The panel's readout: a tracked label in secondary ink with its value in the
/// section colour, bold.
struct LabelValue: View {
    let label: String
    let value: String
    var color: Color = Sungam.ink85
    var size: CGFloat = Sungam.textBase

    var body: some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(Sungam.mono(size))
                .tracking(size * Sungam.scale * 0.04)
                .foregroundStyle(Sungam.ink62)
            Text(value)
                .font(Sungam.mono(size, weight: .bold))
                .foregroundStyle(color)
        }
    }
}
