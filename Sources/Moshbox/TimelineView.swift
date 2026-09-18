import MoshCore
import SwiftUI

/// Waveform, onset curve, trigger lane and playhead in one canvas.
///
/// Everything the render will do is visible here: each tick is a trigger, and
/// the bar under it is the span of video the rule will chew through.
struct TimelineView: View {
    @EnvironmentObject var model: AppModel

    private var duration: Double { max(model.info?.duration ?? 0, 0.001) }

    var body: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)
            let h = Double(geo.size.height)
            let waveH: Double = h * 0.52
            let laneY: Double = waveH + 14
            let laneH: Double = max(0, h - laneY - 16)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawWaveform(ctx, size: size, height: waveH)
                    drawFlux(ctx, size: size, height: waveH)
                    drawOpSpans(ctx, size: size, laneY: laneY, laneH: laneH)
                    drawTriggers(ctx, size: size, waveH: waveH, laneY: laneY)
                    drawPlayhead(ctx, size: size)
                }
                .background(Color.black.opacity(0.35))

                if model.envelope.isEmpty && !model.analysing {
                    Text(model.info?.hasAudio == false
                         ? "Source has no audio — use MIDI or manual triggers"
                         : "Load a video to see its waveform")
                        .font(.caption)
                        .foregroundStyle(Theme.dim)
                        .padding(10)
                }
                if model.analysing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analysing audio…").font(.caption).foregroundStyle(Theme.dim)
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
                // Double-click drops a manual trigger at the playhead.
                model.addManualTrigger(at: model.currentTime)
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
    }

    private func x(_ time: Double, _ width: Double) -> Double {
        width * min(max(0, time / duration), 1)
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
        ctx.stroke(path, with: .color(Theme.wave.opacity(0.55)), lineWidth: max(1, step))
    }

    private func drawFlux(_ ctx: GraphicsContext, size: CGSize, height: Double) {
        let flux = model.fluxCurve
        guard flux.count > 1 else { return }
        var path = Path()
        let step = size.width / Double(flux.count - 1)
        for (i, v) in flux.enumerated() {
            let p = CGPoint(x: Double(i) * step, y: height - Double(v) * height * 0.9)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.stroke(path, with: .color(Color.white.opacity(0.28)), lineWidth: 1)
    }

    /// Shade the frames each rule will actually rewrite, so overlapping effects
    /// are obvious before you spend a render on them.
    private func drawOpSpans(_ ctx: GraphicsContext, size: CGSize, laneY: Double, laneH: Double) {
        guard laneH > 0 else { return }
        let active = model.rules.filter(\.enabled)
        guard !active.isEmpty else { return }
        let rowH = min(10.0, laneH / Double(active.count))

        for (row, rule) in active.enumerated() {
            let y = laneY + Double(row) * (rowH + 2)
            for event in model.events where rule.matches(event) {
                let x0 = x(event.time + rule.offset, size.width)
                let x1 = x(event.time + rule.offset + rule.duration, size.width)
                let rect = CGRect(x: x0, y: y, width: max(1.5, x1 - x0), height: rowH - 2)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                         with: .color(color(for: rule.kind).opacity(0.65)))
            }
        }
    }

    private func drawTriggers(_ ctx: GraphicsContext, size: CGSize, waveH: Double, laneY: Double) {
        for event in model.events {
            let px = x(event.time, size.width)
            var path = Path()
            path.move(to: CGPoint(x: px, y: 0))
            path.addLine(to: CGPoint(x: px, y: laneY - 4))
            let c: Color = switch event.source {
            case .audio: Theme.accent
            case .midi: Color(red: 0.55, green: 0.75, blue: 1.0)
            case .manual: Color.white
            }
            ctx.stroke(path, with: .color(c.opacity(0.25 + 0.6 * event.strength)),
                       lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: px - 2.5, y: waveH + 2, width: 5, height: 5)),
                     with: .color(c))
        }
    }

    private func drawPlayhead(_ ctx: GraphicsContext, size: CGSize) {
        let px = x(model.currentTime, size.width)
        var path = Path()
        path.move(to: CGPoint(x: px, y: 0))
        path.addLine(to: CGPoint(x: px, y: size.height))
        ctx.stroke(path, with: .color(model.isArmed ? Theme.hot : Color.white.opacity(0.8)),
                   lineWidth: model.isArmed ? 2 : 1)
    }

    func color(for kind: MoshOpKind) -> Color {
        switch kind {
        case .bloom: return Color(red: 1.00, green: 0.42, blue: 0.20)
        case .glide: return Color(red: 0.40, green: 0.85, blue: 0.55)
        case .echo: return Color(red: 0.55, green: 0.60, blue: 1.00)
        case .stutter: return Color(red: 0.95, green: 0.75, blue: 0.20)
        case .reverse: return Color(red: 0.90, green: 0.40, blue: 0.80)
        case .shuffle: return Color(red: 0.40, green: 0.80, blue: 0.90)
        case .freeze: return Color(red: 0.70, green: 0.72, blue: 0.78)
        }
    }
}
