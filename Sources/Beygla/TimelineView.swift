import MoshCore
import SwiftUI

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
    @State private var paint: (ruleID: UUID, from: Double, to: Double)?

    private let waveH: Double = 96
    private let rowH: Double = 17
    private let gap: Double = 10

    private var duration: Double { max(model.info?.duration ?? 0, 0.001) }
    private var lanes: [MoshRule] { model.rules.filter(\.enabled) }
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
                    model.removeRegion(from: rule.id, at: t)
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
                            paint = (p.ruleID, p.from, time(at: g.location.x, width: w))
                        } else if g.startLocation.y < laneY {
                            model.seek(to: time(at: g.location.x, width: w))
                        } else if let rule = lane(at: g.startLocation.y) {
                            paint = (rule.id,
                                     time(at: g.startLocation.x, width: w),
                                     time(at: g.location.x, width: w))
                        }
                    }
                    .onEnded { _ in
                        if let p = paint {
                            model.addRegion(to: p.ruleID, from: p.from, to: p.to)
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

    private func lane(at y: CGFloat) -> MoshRule? {
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
            let color = rule.kind.signalColor

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

            ctx.draw(Text(rule.kind.displayName.uppercased() + (live ? "  ALWAYS" : ""))
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
