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

    // The graphite edition: paper and ink trade places, so every rule written
    // in terms of them — hairlines at partial ink, fills on paper — still
    // holds. A light chrome glares next to the picture and skews how the mosh
    // reads; a mid-dark grey keeps out of its way without going to black.
    static let paper = Color(red: 0.180, green: 0.176, blue: 0.169)   // #2e2d2b
    static let ink = Color(red: 0.925, green: 0.910, blue: 0.875)     // #ece8df

    /// Behind the picture only: a step darker than the panels, so the video's
    /// frame is its own edge rather than a border drawn around it.
    static let stage = Color(red: 0.125, green: 0.122, blue: 0.118)   // #201f1e

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
    // Steel, violet and the lilac text are lifted a step from the light
    // edition: at their old values they sank into the dark paper.
    static let steel = Color(red: 0.400, green: 0.584, blue: 0.761)   // #6695c2
    static let violet = Color(red: 0.549, green: 0.490, blue: 0.878)  // #8c7de0
    static let amber = Color(red: 0.851, green: 0.639, blue: 0.161)   // #d9a329
    static let lilac = Color(red: 0.827, green: 0.655, blue: 0.863)   // #d3a7dc
    static let lilacText = Color(red: 0.741, green: 0.553, blue: 0.808)  // #bd8dce

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

// MARK: - NumBox

/// A number in a box — the system's compact value control, standing in for
/// the rotary knob wherever space matters (which, in an inspector, is
/// everywhere). A faint fill behind the digits shows where the value sits in
/// its range, growing from the left, or from the centre when bipolar.
///
/// Drag up or down to change it, shift for a finer drag. Double-click to type
/// a value, in the units the box displays (`entryScale` converts: a box that
/// shows milliseconds of a value held in seconds passes 1000).
struct NumBox: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0 ... 1
    var color: Color = Sungam.coral
    var bipolar: Bool = false
    var entryScale: Double = 1
    /// Drags snap to this step; typed values do not, so a tempo can drag in
    /// whole BPM and still take 127.5 from the keyboard.
    var dragStep: Double? = nil
    /// Label beside the box instead of above it, for a single-row strip.
    var inline: Bool = false
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    @State private var dragStart: Double?
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var norm: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        if inline {
            HStack(spacing: 6) {
                caption.fixedSize()
                box.frame(width: 62 * Sungam.scale)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                caption
                box
            }
            .frame(minWidth: 54 * Sungam.scale, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var caption: some View {
        Text(label.uppercased())
            .font(Sungam.mono(Sungam.text2xs))
            .tracking(Sungam.text2xs * Sungam.scale * 0.06)
            .foregroundStyle(Sungam.ink55)
            .lineLimit(1)
    }

    private var box: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                fill(width: geo.size.width)
                if editing {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(Sungam.mono(Sungam.textBase, weight: .bold))
                        .foregroundStyle(Sungam.ink)
                        .padding(.horizontal, 6)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, f in if !f && editing { commit() } }
                } else {
                    Text(format(value))
                        .font(Sungam.mono(Sungam.textBase, weight: .bold).monospacedDigit())
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: 19 * Sungam.scale)
        .background(Sungam.ink(0.04))
        .overlay(Rectangle().stroke(editing ? color : Sungam.ink22, lineWidth: Sungam.hairline))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { g in
                    guard !editing else { return }
                    let fine = NSEvent.modifierFlags.contains(.shift)
                    let base = dragStart ?? norm
                    if dragStart == nil { dragStart = norm }
                    let gain = fine ? 0.001 : 0.005
                    let next = min(max(base - Double(g.translation.height) * gain, 0), 1)
                    var v = range.lowerBound + next * (range.upperBound - range.lowerBound)
                    if let step = dragStep { v = (v / step).rounded() * step }
                    value = v
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            text = String(format: "%g", (value * entryScale * 1000).rounded() / 1000)
            editing = true
            focused = true
        })
        .help("Drag up/down to change, shift for fine, double-click to type")
    }

    @ViewBuilder
    private func fill(width: CGFloat) -> some View {
        if bipolar {
            let mid = width / 2
            let x = width * norm
            Rectangle().fill(color.opacity(0.22))
                .frame(width: abs(x - mid))
                .offset(x: min(x, mid))
            Rectangle().fill(Sungam.ink22).frame(width: 1).offset(x: mid)
        } else {
            Rectangle().fill(color.opacity(0.22)).frame(width: width * norm)
        }
    }

    private func commit() {
        let cleaned = text.filter { "0123456789.-+".contains($0) }
        if let v = Double(cleaned) {
            value = min(max(v / entryScale, range.lowerBound), range.upperBound)
        }
        editing = false
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

// MARK: - DropdownLatch

/// A Selector folded into one filled latch: it shows the current position,
/// and a click opens a plain menu of all of them. For a choice made rarely
/// enough that it should not spend a whole row of the panel. Drawn by hand
/// rather than with SwiftUI's `Menu`, which styles its label its own way.
struct DropdownLatch<T: Hashable>: View {
    let label: String
    var color: Color = Sungam.coral
    let options: [(value: T, label: String)]
    let selection: T
    let choose: (T) -> Void

    var body: some View {
        Text("\(label.uppercased())  ▾")
            .font(Sungam.mono(Sungam.textXs))
            .tracking(Sungam.textXs * Sungam.scale * 0.02)
            .foregroundStyle(Sungam.paper)
            .padding(.horizontal, 10)
            .frame(height: 17 * Sungam.scale)
            .background(color)
            .contentShape(Rectangle())
            .onTapGesture { popUp() }
    }

    private func popUp() {
        let menu = NSMenu()
        for opt in options {
            let item = ClosureMenuItem(title: opt.label) { choose(opt.value) }
            item.state = opt.value == selection ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
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

// MARK: - Fader

/// A flat track with a small handle — the system's linear control, next to
/// the NumBox's stepped one. The tokens describe it vertical (`--fader-travel`
/// is a throw in px, sized for a mixer-style channel strip); this is the
/// horizontal adaptation, which suits a control paired with a horizontal
/// timeline better than a rotary one would. The handle is one of exactly two
/// places in the whole system that gets a rounded corner — the other is the
/// track itself — everything else on the panel stays square.
struct Fader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0 ... 1
    var color: Color = Sungam.coral
    var width: CGFloat = 130

    @State private var dragStartValue: Double?

    private var norm: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        let trackH: CGFloat = 6 * Sungam.scale
        let handleW: CGFloat = 14 * Sungam.scale
        let handleH: CGFloat = 16 * Sungam.scale
        let w = width * Sungam.scale

        ZStack(alignment: .leading) {
            Capsule()
                .fill(Sungam.ink13)
                .frame(width: w, height: trackH)
            Capsule()
                .fill(color.opacity(0.55))
                .frame(width: max(handleW / 2, w * norm), height: trackH)
            RoundedRectangle(cornerRadius: 3)
                .fill(Sungam.paper)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: Sungam.borderDefault))
                .frame(width: handleW, height: handleH)
                .offset(x: min(max(0, w * norm - handleW / 2), w - handleW))
        }
        .frame(width: w, height: handleH)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStartValue == nil { dragStartValue = value }
                    let frac = min(max(0, Double(g.location.x) / Double(w)), 1)
                    value = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in dragStartValue = nil }
        )
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
