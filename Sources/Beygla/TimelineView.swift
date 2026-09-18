import MoshCore
import SwiftUI

/// Waveform, onset curve, trigger lane and playhead, drawn as one instrument
/// readout.
///
/// Everything the render will do is visible here: each tick is a trigger, and
/// the bar beneath it is the exact span of frames its rule will rewrite.
struct TimelineView: View {
    @EnvironmentObject var model: AppModel

    private var duration: Double { max(model.info?.duration ?? 0, 0.001) }

    var body: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)
            let h = Double(geo.size.height)
            let waveH: Double = h * 0.50
            let laneY: Double = waveH + 16
            let laneH: Double = max(0, h - laneY - 10)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawGrid(ctx, size: size, waveH: waveH)
                    drawWaveform(ctx, size: size, height: waveH)
                    drawFlux(ctx, size: size, height: waveH)
                    drawOpSpans(ctx, size: size, laneY: laneY, laneH: laneH)
                    drawTriggers(ctx, size: size, waveH: waveH, laneY: laneY)
                    drawPlayhead(ctx, size: size)
                }

                if model.envelope.isEmpty && !model.analysing {
                    Text(model.info?.hasAudio == false
                         ? "Source has no audio — use MIDI or manual triggers"
                         : "Load a video to see its waveform")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(Sungam.ink38)
                        .padding(10)
                }
                if model.analysing {
                    HStack(spacing: 6) {
                        Lamp(on: true, color: Sungam.coral, size: 7)
                        Text("ANALYSING AUDIO")
                            .font(Sungam.mono(Sungam.textSm))
                            .tracking(Sungam.textSm * Sungam.scale * 0.08)
                            .foregroundStyle(Sungam.ink62)
                    }
                    .padding(10)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let t = Double(g.location.x) / max(w, 1) * duration
                        model.seek(to: min(max(0, t), duration))
                    }
            )
            .onTapGesture(count: 2) {
                model.addManualTrigger(at: model.currentTime)
            }
        }
        .frame(height: 160)
        .overlay(Rectangle().stroke(Sungam.ink28, lineWidth: Sungam.hairline))
    }

    private func x(_ time: Double, _ width: Double) -> Double {
        width * min(max(0, time / duration), 1)
    }

    /// A one-second rule, so the eye can read where a hit lands without a
    /// separate ruler strip.
    private func drawGrid(_ ctx: GraphicsContext, size: CGSize, waveH: Double) {
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

    private func drawWaveform(_ ctx: GraphicsContext, size: CGSize, height: Double) {
        let env = model.envelope
        guard !env.isEmpty else { return }
        let mid = height / 2
        var path = Path()
        let step = size.width / Double(env.count)
        for (i, v) in env.enumerated() {
            let px = Double(i) * step
            let half = Double(v) * (height / 2) * 0.95
            path.move(to: CGPoint(x: px, y: mid - half))
            path.addLine(to: CGPoint(x: px, y: mid + half))
        }
        ctx.stroke(path, with: .color(Sungam.ink45), lineWidth: max(1, step))
    }

    /// The detection curve the threshold acts on — drawn so the sensitivity
    /// knob has something visible to move against.
    private func drawFlux(_ ctx: GraphicsContext, size: CGSize, height: Double) {
        let flux = model.fluxCurve
        guard flux.count > 1 else { return }
        var path = Path()
        let step = size.width / Double(flux.count - 1)
        for (i, v) in flux.enumerated() {
            let p = CGPoint(x: Double(i) * step, y: height - Double(v) * height * 0.9)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.stroke(path, with: .color(Sungam.coral.opacity(0.7)), lineWidth: Sungam.hairline)
    }

    /// One row per enabled rule, shading the frames it will rewrite.
    private func drawOpSpans(_ ctx: GraphicsContext, size: CGSize, laneY: Double, laneH: Double) {
        guard laneH > 0 else { return }
        let active = model.rules.filter(\.enabled)
        guard !active.isEmpty else { return }
        let rowH = min(9.0, laneH / Double(active.count))

        for (row, rule) in active.enumerated() {
            let y = laneY + Double(row) * (rowH + 2)
            guard y + rowH <= size.height else { break }
            for event in model.events where rule.matches(event) {
                let x0 = x(event.time + rule.offset, size.width)
                let x1 = x(event.time + rule.offset + rule.duration, size.width)
                let rect = CGRect(x: x0, y: y, width: max(1.5, x1 - x0), height: rowH - 2)
                ctx.fill(Path(rect), with: .color(rule.kind.signalColor))
            }
        }
    }

    private func drawTriggers(_ ctx: GraphicsContext, size: CGSize, waveH: Double, laneY: Double) {
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
            path.addLine(to: CGPoint(x: px, y: laneY - 5))
            ctx.stroke(path, with: .color(c.opacity(0.28 + 0.6 * event.strength)),
                       lineWidth: Sungam.hairline)
            // A filled square marks the hit itself — the panel's lamp vocabulary.
            ctx.fill(Path(CGRect(x: px - 2, y: waveH + 3, width: 4, height: 4)),
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
