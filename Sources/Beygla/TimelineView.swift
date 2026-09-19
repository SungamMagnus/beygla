import MoshCore
import SwiftUI

/// One row on the timeline: either a bitstream rule or a vector rule. The
/// canvas draws and paints both families through this one shape rather than
/// duplicating the whole lane/gesture system, which is what makes adding the
/// second effect family to the timeline a small change instead of a second
/// copy of TimelineView.
private enum LaneRule: Identifiable {
    case bitstream(MoshRule)
    case vector(VectorRule)

    var id: UUID {
        switch self {
        case .bitstream(let r): return r.id
        case .vector(let r): return r.id
        }
    }
    var displayName: String {
        switch self {
        case .bitstream(let r): return r.kind.displayName
        case .vector(let r): return r.kind.displayName
        }
    }
    var color: Color {
        switch self {
        case .bitstream(let r): return r.kind.signalColor
        case .vector(let r): return r.kind.signalColor
        }
    }
    var activeRegions: [ActiveRegion] {
        switch self {
        case .bitstream(let r): return r.activeRegions
        case .vector(let r): return r.activeRegions
        }
    }
    func matches(_ event: TriggerEvent) -> Bool {
        switch self {
        case .bitstream(let r): return r.matches(event)
        case .vector(let r): return r.matches(event)
        }
    }
    var offset: Double {
        switch self {
        case .bitstream(let r): return r.offset
        case .vector(let r): return r.offset
        }
    }
    var duration: Double {
        switch self {
        case .bitstream(let r): return r.duration
        case .vector(let r): return r.duration
        }
    }
}

/// Waveform and onset curve on top, one lane per enabled effect underneath.
///
/// The lanes are the point of the view. A rule with no painted span is live for
/// the whole clip, which means every effect fires on every trigger; paint spans
/// and the effects take turns instead. Everything the render will do is visible
/// here — each tick is a trigger, each solid bar is frames that will actually be
/// rewritten, and the tint behind them is where that effect is listening.
struct TimelineView: View {
    @EnvironmentObject var model: AppModel

    /// An in-progress paint, held until the drag ends.
    private enum PaintKind { case bitstream, vector }
    @State private var paint: (ruleID: UUID, kind: PaintKind, from: Double, to: Double)?

    private let waveH: Double = 96
    private let rowH: Double = 17
    private let gap: Double = 10

    private var duration: Double { max(model.info?.duration ?? 0, 0.001) }
    private var lanes: [LaneRule] {
        model.rules.filter(\.enabled).map(LaneRule.bitstream)
            + model.vectorRules.filter(\.enabled).map(LaneRule.vector)
    }
    private var laneY: Double { waveH + gap }
    private var height: Double { laneY + Double(max(lanes.count, 1)) * rowH + 8 }

    var body: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)

            Canvas { ctx, size in
                drawGrid(ctx, size: size)
                drawWaveform(ctx, size: size)
                drawFlux(ctx, size: size)
                drawLanes(ctx, size: size)
                drawTriggers(ctx, size: size)
                drawPlayhead(ctx, size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { p in
                let t = time(at: p.x, width: w)
                if p.y < laneY {
                    model.addManualTrigger(at: t)
                } else if let rule = lane(at: p.y) {
                    // Double-click inside a span removes it.
                    switch rule {
                    case .bitstream(let r): model.removeRegion(from: r.id, at: t)
                    case .vector(let r): model.removeVectorRegion(from: r.id, at: t)
                    }
                }
            }
            .onTapGesture(count: 1) { p in
                if p.y < laneY { model.seek(to: time(at: p.x, width: w)) }
            }
            // A click is a zero-distance drag, so a drag that accepts one would
            // swallow every tap before either tap gesture saw it.
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { g in
                        if let p = paint {
                            paint = (p.ruleID, p.kind, p.from, time(at: g.location.x, width: w))
                        } else if g.startLocation.y < laneY {
                            model.seek(to: time(at: g.location.x, width: w))
                        } else if let rule = lane(at: g.startLocation.y) {
                            let kind: PaintKind = { if case .vector = rule { return .vector }; return .bitstream }()
                            paint = (rule.id, kind,
                                     time(at: g.startLocation.x, width: w),
                                     time(at: g.location.x, width: w))
                        }
                    }
                    .onEnded { _ in
                        if let p = paint {
                            switch p.kind {
                            case .bitstream: model.addRegion(to: p.ruleID, from: p.from, to: p.to)
                            case .vector: model.addVectorRegion(to: p.ruleID, from: p.from, to: p.to)
                            }
                        }
                        paint = nil
                    }
            )
            .overlay(alignment: .topLeading) { status }
        }
        .frame(height: height)
        .overlay(Rectangle().stroke(Sungam.ink28, lineWidth: Sungam.hairline))
    }

    @ViewBuilder private var status: some View {
        if model.analysing {
            HStack(spacing: 6) {
                Lamp(on: true, color: Sungam.coral, size: 7)
                Text("ANALYSING AUDIO")
                    .font(Sungam.mono(Sungam.textSm))
                    .tracking(Sungam.textSm * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.ink62)
            }
            .padding(10)
        } else if model.envelope.isEmpty {
            Text(model.info?.hasAudio == false && model.audioURL == nil
                 ? "No audio — load a track, or use MIDI and hand-placed triggers"
                 : "Load a video to see its waveform")
                .font(Sungam.mono(Sungam.textSm))
                .foregroundStyle(Sungam.ink38)
                .padding(10)
        }
    }

    // MARK: Geometry

    private func x(_ t: Double, _ width: Double) -> Double {
        width * min(max(0, t / duration), 1)
    }

    private func time(at x: CGFloat, width: Double) -> Double {
        min(max(0, Double(x) / max(width, 1) * duration), duration)
    }

    private func lane(at y: CGFloat) -> LaneRule? {
        let row = Int((Double(y) - laneY) / rowH)
        guard row >= 0, row < lanes.count else { return nil }
        return lanes[row]
    }

    private func rowRect(_ row: Int, _ size: CGSize) -> CGRect {
        CGRect(x: 0, y: laneY + Double(row) * rowH, width: size.width, height: rowH - 2)
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize) {
        guard duration > 0.5 else { return }
        let step = duration > 30 ? 5.0 : 1.0
        var t = step
        while t < duration {
            var p = Path()
            let px = x(t, size.width)
            p.move(to: CGPoint(x: px, y: 0))
            p.addLine(to: CGPoint(x: px, y: size.height))
            ctx.stroke(p, with: .color(Sungam.ink08), lineWidth: Sungam.hairline)
            t += step
        }
        var mid = Path()
        mid.move(to: CGPoint(x: 0, y: waveH / 2))
        mid.addLine(to: CGPoint(x: size.width, y: waveH / 2))
        ctx.stroke(mid, with: .color(Sungam.ink13), lineWidth: Sungam.hairline)
    }

    private func drawWaveform(_ ctx: GraphicsContext, size: CGSize) {
        let env = model.envelope
        guard !env.isEmpty else { return }
        let mid = waveH / 2
        var path = Path()
        let step = size.width / Double(env.count)
        for (i, v) in env.enumerated() {
            let px = Double(i) * step
            let half = Double(v) * (waveH / 2) * 0.95
            path.move(to: CGPoint(x: px, y: mid - half))
            path.addLine(to: CGPoint(x: px, y: mid + half))
        }
        ctx.stroke(path, with: .color(Sungam.ink45), lineWidth: max(1, step))
    }

    /// The detection curve the threshold acts on — drawn so the sensitivity
    /// knob has something visible to move against.
    private func drawFlux(_ ctx: GraphicsContext, size: CGSize) {
        let flux = model.fluxCurve
        guard flux.count > 1 else { return }
        var path = Path()
        let step = size.width / Double(flux.count - 1)
        for (i, v) in flux.enumerated() {
            let p = CGPoint(x: Double(i) * step, y: waveH - Double(v) * waveH * 0.9)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.stroke(path, with: .color(Sungam.coral.opacity(0.7)), lineWidth: Sungam.hairline)
    }

    private func drawLanes(_ ctx: GraphicsContext, size: CGSize) {
        guard !lanes.isEmpty else {
            ctx.draw(Text("NO EFFECTS ENABLED")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink38),
                     at: CGPoint(x: 8, y: laneY + 8), anchor: .leading)
            return
        }

        for (row, rule) in lanes.enumerated() {
            let rect = rowRect(row, size)
            let color = rule.color

            // The lane itself.
            ctx.fill(Path(rect), with: .color(Sungam.ink.opacity(0.035)))

            let live = rule.activeRegions.isEmpty
            if live {
                // No spans painted: the effect is listening the whole way.
                ctx.fill(Path(rect), with: .color(color.opacity(0.10)))
            } else {
                for region in rule.activeRegions {
                    let r = CGRect(x: x(region.start, size.width), y: rect.minY,
                                   width: max(2, x(region.end, size.width)
                                                 - x(region.start, size.width)),
                                   height: rect.height)
                    ctx.fill(Path(r), with: .color(color.opacity(0.20)))
                    ctx.stroke(Path(r), with: .color(color.opacity(0.55)),
                               lineWidth: Sungam.hairline)
                }
            }

            // The span currently being dragged out.
            if let p = paint, p.ruleID == rule.id {
                let r = CGRect(x: x(min(p.from, p.to), size.width), y: rect.minY,
                               width: max(2, abs(x(p.to, size.width) - x(p.from, size.width))),
                               height: rect.height)
                ctx.fill(Path(r), with: .color(color.opacity(0.32)))
                ctx.stroke(Path(r), with: .color(color), lineWidth: Sungam.borderDefault)
            }

            // The frames this rule will actually rewrite.
            for event in model.events where rule.matches(event) {
                let x0 = x(event.time + rule.offset, size.width)
                let x1 = x(event.time + rule.offset + rule.duration, size.width)
                let bar = CGRect(x: x0, y: rect.minY + 3,
                                 width: max(1.5, x1 - x0), height: rect.height - 6)
                ctx.fill(Path(bar), with: .color(color))
            }

            ctx.draw(Text(rule.displayName.uppercased() + (live ? "  ALWAYS" : ""))
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink62),
                     at: CGPoint(x: 6, y: rect.midY), anchor: .leading)
        }
    }

    private func drawTriggers(_ ctx: GraphicsContext, size: CGSize) {
        for event in model.events {
            let px = x(event.time, size.width)
            // Source is read from the tick's colour: coral for audio, steel for
            // MIDI, plain ink for a hand-placed one.
            let c: Color = switch event.source {
            case .audio: Sungam.coral
            case .midi: Sungam.steel
            case .manual: Sungam.ink70
            }
            var path = Path()
            path.move(to: CGPoint(x: px, y: 0))
            path.addLine(to: CGPoint(x: px, y: laneY - 4))
            ctx.stroke(path, with: .color(c.opacity(0.28 + 0.6 * event.strength)),
                       lineWidth: Sungam.hairline)
            // A filled square marks the hit — the panel's lamp vocabulary.
            ctx.fill(Path(CGRect(x: px - 2, y: waveH + 2, width: 4, height: 4)),
                     with: .color(c))
        }
    }

    private func drawPlayhead(_ ctx: GraphicsContext, size: CGSize) {
        let px = x(model.currentTime, size.width)
        var path = Path()
        path.move(to: CGPoint(x: px, y: 0))
        path.addLine(to: CGPoint(x: px, y: size.height))
        ctx.stroke(path, with: .color(model.isArmed ? Sungam.amber : Sungam.ink85),
                   lineWidth: model.isArmed ? Sungam.borderStrong : Sungam.hairline)
    }
}
