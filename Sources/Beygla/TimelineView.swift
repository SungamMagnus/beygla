import AppKit
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
    private enum Marker { case inPoint, outPoint }
    /// An in or out flag being dragged.
    @State private var markerDrag: Marker?
    @State private var hoveringMarker = false
    @State private var paint: (ruleID: UUID, kind: PaintKind, from: Double, to: Double)?
    /// One of a lane's own triggers being dragged.
    @State private var triggerDrag: UUID?

    private let waveH: Double = 96
    private let rowH: Double = 17
    /// An open lane: a header strip to click closed, and a body tall enough
    /// that a trigger's height can stand for its strength.
    private let openH: Double = 76
    private let headerH: Double = 16
    private let gap: Double = 10

    private var duration: Double { max(model.info?.duration ?? 0, 0.001) }
    private var lanes: [LaneRule] {
        model.rules.filter(\.enabled).map(LaneRule.bitstream)
            + model.vectorRules.filter(\.enabled).map(LaneRule.vector)
    }
    private var laneY: Double { waveH + gap }

    /// Each lane's rule, vertical extent and whether it is open — collapsed
    /// lanes stay one row high, so many effects still fit.
    private struct LaneSlot {
        let rule: LaneRule
        let y: Double
        let h: Double
        let open: Bool
    }

    private var slots: [LaneSlot] {
        var y = laneY
        return lanes.map { rule in
            let open = model.expandedLanes.contains(rule.id)
            let h = open ? openH : rowH
            defer { y += h }
            return LaneSlot(rule: rule, y: y, h: h, open: open)
        }
    }

    private var height: Double {
        let lanesH = slots.reduce(0) { $0 + $1.h }
        return laneY + max(lanesH, rowH) + 8
    }

    var body: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)

            TrackpadGestureCapture(
                onMagnify: { factor, xFraction in
                    // Anchor the zoom on where the pinch is centred, in the
                    // window as it stood *before* this event, so the point
                    // under the cursor is the point that stays under it.
                    let anchor = time(at: xFraction * geo.size.width, width: w)
                    model.setTimelineZoom(model.timelineZoom * factor, anchoredAt: anchor)
                },
                onPanX: { deltaX in
                    guard model.timelineZoom > 1 else { return }
                    let secondsPerPoint = visibleDuration / max(w, 1)
                    // Two fingers moving left uncovers content further along
                    // in time — the window should advance to meet them.
                    model.panTimeline(bySeconds: deltaX * secondsPerPoint)
                }
            ) {
                Canvas { ctx, size in
                    drawGrid(ctx, size: size)
                    drawWaveform(ctx, size: size)
                    drawFlux(ctx, size: size)
                    drawLanes(ctx, size: size)
                    drawTriggers(ctx, size: size)
                    drawInOut(ctx, size: size)
                    drawPlayhead(ctx, size: size)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { p in
                    if marker(at: p, width: w) != nil { return }
                    let t = time(at: p.x, width: w)
                    if p.y < laneY {
                        model.addManualTrigger(at: t)
                    } else if let slot = slot(at: p.y) {
                        // On an open lane, double-clicking one of its own
                        // triggers deletes it; anywhere else in a lane,
                        // double-clicking inside a span removes the span.
                        if slot.open, let id = ownTrigger(at: p, in: slot, width: w) {
                            model.removeTrigger(id)
                            return
                        }
                        switch slot.rule {
                        case .bitstream(let r): model.removeRegion(from: r.id, at: t)
                        case .vector(let r): model.removeVectorRegion(from: r.id, at: t)
                        }
                    }
                }
                .onTapGesture(count: 1) { p in
                    if marker(at: p, width: w) != nil { return }
                    if p.y < laneY {
                        model.seek(to: time(at: p.x, width: w))
                    } else if let slot = slot(at: p.y) {
                        // A collapsed lane, or an open lane's header strip,
                        // opens or closes it. A click in an open lane's body
                        // places a trigger for that effect alone, as strong
                        // as the click is high.
                        if !slot.open || Double(p.y) < slot.y + headerH {
                            model.toggleLane(slot.rule.id)
                        } else if ownTrigger(at: p, in: slot, width: w) == nil {
                            model.addTrigger(for: slot.rule.id, at: time(at: p.x, width: w),
                                             strength: strength(at: p.y, in: slot))
                        }
                    }
                }
                // A click is a zero-distance drag, so a drag that accepts one
                // would swallow every tap before either tap gesture saw it.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { g in
                            // A drag that starts on a flag moves that flag and
                            // nothing else — checked before scrub and paint.
                            if markerDrag == nil, paint == nil,
                               let m = marker(at: g.startLocation, width: w) {
                                markerDrag = m
                            }
                            if let m = markerDrag {
                                let t = time(at: g.location.x, width: w)
                                switch m {
                                case .inPoint: model.moveInPoint(to: t)
                                case .outPoint: model.moveOutPoint(to: t)
                                }
                                return
                            }
                            // A drag that starts on one of an open lane's own
                            // triggers moves it: sideways in time, up and
                            // down in strength.
                            if triggerDrag == nil, paint == nil,
                               let slot = slot(at: g.startLocation.y), slot.open,
                               let id = ownTrigger(at: g.startLocation, in: slot, width: w) {
                                triggerDrag = id
                            }
                            if let id = triggerDrag, let slot = slot(at: g.startLocation.y) {
                                model.moveTrigger(id, to: time(at: g.location.x, width: w),
                                                  strength: strength(at: g.location.y, in: slot))
                                return
                            }
                            if let p = paint {
                                paint = (p.ruleID, p.kind, p.from, time(at: g.location.x, width: w))
                            } else if g.startLocation.y < laneY {
                                model.seek(to: time(at: g.location.x, width: w))
                            } else if let rule = slot(at: g.startLocation.y)?.rule {
                                let kind: PaintKind = { if case .vector = rule { return .vector }; return .bitstream }()
                                paint = (rule.id, kind,
                                         time(at: g.startLocation.x, width: w),
                                         time(at: g.location.x, width: w))
                            }
                        }
                        .onEnded { _ in
                            markerDrag = nil
                            triggerDrag = nil
                            if let p = paint {
                                switch p.kind {
                                case .bitstream: model.addRegion(to: p.ruleID, from: p.from, to: p.to)
                                case .vector: model.addVectorRegion(to: p.ruleID, from: p.from, to: p.to)
                                }
                            }
                            paint = nil
                        }
                )
                .onContinuousHover { phase in
                    let over: Bool
                    if case .active(let p) = phase { over = marker(at: p, width: w) != nil } else { over = false }
                    if over != hoveringMarker {
                        hoveringMarker = over
                        if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                }
                .overlay(alignment: .topLeading) { status }
            }
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

    // Zoom narrows which slice of the clip `x`/`time(at:)` map against.
    // `duration` (the whole clip) still bounds what a value clamps to, but
    // every pixel-to-time conversion below goes through the visible window
    // — `timelineOffset ..< timelineOffset + visibleDuration` — instead.
    private var visibleStart: Double { model.timelineOffset }
    private var visibleDuration: Double { model.timelineVisibleDuration }

    // Deliberately unclamped: Canvas already clips its drawing to its own
    // bounds, so a sample outside the visible window maps to a pixel outside
    // [0, width] and is simply not rendered, rather than being dragged to
    // the edge and drawn there as a false mark.
    private func x(_ t: Double, _ width: Double) -> Double {
        width * (t - visibleStart) / visibleDuration
    }

    private func time(at x: CGFloat, width: Double) -> Double {
        let t = visibleStart + Double(x) / max(width, 1) * visibleDuration
        return min(max(0, t), duration)
    }

    /// The IN and OUT flags are the grab handles — the same rectangles the
    /// labels are drawn in, with a few points of slack around them.
    private func marker(at p: CGPoint, width: Double) -> Marker? {
        guard p.y < 18 else { return nil }
        let px = Double(p.x)
        if let t = model.inPoint {
            let x0 = x(t, width)
            if px >= x0 - 4 && px <= x0 + 26 { return .inPoint }
        }
        if let t = model.outPoint {
            let x0 = x(t, width)
            if px >= x0 - 32 && px <= x0 + 4 { return .outPoint }
        }
        return nil
    }

    private func slot(at y: CGFloat) -> LaneSlot? {
        let y = Double(y)
        return slots.first { y >= $0.y && y < $0.y + $0.h }
    }

    private func laneRect(_ slot: LaneSlot, _ width: Double) -> CGRect {
        CGRect(x: 0, y: slot.y, width: width, height: slot.h - 2)
    }

    /// Where an open lane's triggers stand: below the header strip, above
    /// the bar of rewritten frames along the bottom.
    private func bodyRect(_ slot: LaneSlot, _ width: Double) -> CGRect {
        CGRect(x: 0, y: slot.y + headerH, width: width, height: slot.h - headerH - 12)
    }

    private func strength(at y: CGFloat, in slot: LaneSlot) -> Double {
        let body = bodyRect(slot, 1)
        return (body.maxY - Double(y)) / max(body.height, 1)
    }

    /// The lane's own trigger under a point, if any — a few points of slack
    /// either side of its stem.
    private func ownTrigger(at p: CGPoint, in slot: LaneSlot, width: Double) -> UUID? {
        guard Double(p.y) >= slot.y + headerH else { return nil }
        return model.events
            .filter { $0.ruleID == slot.rule.id }
            .map { ($0.id, abs(x($0.time, width) - Double(p.x))) }
            .filter { $0.1 <= 5 }
            .min { $0.1 < $1.1 }?.0
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
        // Samples are spread uniformly across the whole clip; only the ones
        // whose time falls in the visible window are worth iterating.
        let perSample = duration / Double(env.count)
        let lo = max(0, Int(visibleStart / perSample) - 1)
        let hi = min(env.count, Int((visibleStart + visibleDuration) / perSample) + 2)
        guard lo < hi else { return }

        let lineWidth = max(1, size.width / Double(hi - lo))
        var path = Path()
        for i in lo ..< hi {
            let px = x(Double(i) * perSample, size.width)
            let half = Double(env[i]) * (waveH / 2) * 0.95
            path.move(to: CGPoint(x: px, y: mid - half))
            path.addLine(to: CGPoint(x: px, y: mid + half))
        }
        ctx.stroke(path, with: .color(Sungam.ink45), lineWidth: lineWidth)
    }

    /// The detection curve the threshold acts on — drawn so the sensitivity
    /// knob has something visible to move against.
    private func drawFlux(_ ctx: GraphicsContext, size: CGSize) {
        let flux = model.fluxCurve
        guard flux.count > 1 else { return }
        let perSample = duration / Double(flux.count - 1)
        let lo = max(0, Int(visibleStart / perSample) - 1)
        let hi = min(flux.count, Int((visibleStart + visibleDuration) / perSample) + 2)
        guard lo < hi else { return }

        var path = Path()
        var started = false
        for i in lo ..< hi {
            let p = CGPoint(x: x(Double(i) * perSample, size.width),
                            y: waveH - Double(flux[i]) * waveH * 0.9)
            if !started { path.move(to: p); started = true } else { path.addLine(to: p) }
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

        for slot in slots {
            let rule = slot.rule
            let rect = laneRect(slot, size.width)
            let color = rule.color

            // The lane itself.
            ctx.fill(Path(rect), with: .color(Sungam.ink.opacity(slot.open ? 0.06 : 0.035)))

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

            // The frames this rule will actually rewrite, and — when Smear is
            // set — a faint tail for how long the damage lingers after. Open,
            // they run along the lane's foot under the trigger stems.
            let barY = slot.open ? rect.maxY - 10 : rect.minY + 3
            let barH = slot.open ? 7.0 : rect.height - 6
            for event in model.events where rule.matches(event) {
                let x0 = x(event.time + rule.offset, size.width)
                let x1 = x(event.time + rule.offset + rule.duration, size.width)
                if let smear = model.smear, smear > 0 {
                    let x2 = x(event.time + rule.offset + rule.duration + smear, size.width)
                    ctx.fill(Path(CGRect(x: x1, y: barY + barH * 0.3,
                                         width: max(1, x2 - x1), height: barH * 0.4)),
                             with: .color(color.opacity(0.28)))
                }
                let bar = CGRect(x: x0, y: barY, width: max(1.5, x1 - x0), height: barH)
                ctx.fill(Path(bar), with: .color(color))
            }

            if slot.open { drawOpenLane(ctx, slot: slot, size: size) }

            let own = model.events.filter { $0.ruleID == rule.id }.count
            let label = (slot.open ? "▾ " : "▸ ") + rule.displayName.uppercased()
                + (live ? "  ALWAYS" : "") + (own > 0 ? "  \(own) OWN" : "")
            ctx.draw(Text(label)
                        .font(Sungam.mono(Sungam.text2xs, weight: slot.open ? .bold : .regular))
                        .foregroundStyle(slot.open ? Sungam.ink85 : Sungam.ink62),
                     at: CGPoint(x: 6, y: slot.open ? slot.y + headerH / 2 : rect.midY),
                     anchor: .leading)
        }
    }

    /// An open lane's body: shared triggers that reach this effect as faint
    /// full-height stems, and the effect's own triggers as solid stems whose
    /// height is their strength, each topped with a square handle.
    private func drawOpenLane(_ ctx: GraphicsContext, slot: LaneSlot, size: CGSize) {
        let body = bodyRect(slot, size.width)
        let color = slot.rule.color

        var header = Path()
        header.move(to: CGPoint(x: 0, y: body.minY))
        header.addLine(to: CGPoint(x: size.width, y: body.minY))
        ctx.stroke(header, with: .color(Sungam.ink13), lineWidth: Sungam.hairline)
        var base = Path()
        base.move(to: CGPoint(x: 0, y: body.maxY))
        base.addLine(to: CGPoint(x: size.width, y: body.maxY))
        ctx.stroke(base, with: .color(Sungam.ink22), lineWidth: Sungam.hairline)

        for event in model.events where event.ruleID == nil && slot.rule.matches(event) {
            let px = x(event.time, size.width)
            var stem = Path()
            stem.move(to: CGPoint(x: px, y: body.minY + 2))
            stem.addLine(to: CGPoint(x: px, y: body.maxY))
            ctx.stroke(stem, with: .color(Sungam.ink28), lineWidth: Sungam.hairline)
        }

        for event in model.events where event.ruleID == slot.rule.id {
            let px = x(event.time, size.width)
            let top = body.maxY - body.height * event.strength
            let dragging = event.id == triggerDrag
            var stem = Path()
            stem.move(to: CGPoint(x: px, y: top))
            stem.addLine(to: CGPoint(x: px, y: body.maxY))
            ctx.stroke(stem, with: .color(color), lineWidth: dragging ? 2 : 1.5)
            let s: Double = dragging ? 9 : 7
            ctx.fill(Path(CGRect(x: px - s / 2, y: top - s / 2, width: s, height: s)),
                     with: .color(color))
        }

        if !model.events.contains(where: { $0.ruleID == slot.rule.id }) {
            ctx.draw(Text("Click to place a trigger for this effect — higher is stronger")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink38),
                     at: CGPoint(x: size.width / 2, y: body.midY), anchor: .center)
        }
    }

    private func drawTriggers(_ ctx: GraphicsContext, size: CGSize) {
        // A lane's own triggers are drawn in that lane, not across the top.
        for event in model.events where event.ruleID == nil {
            let px = x(event.time, size.width)
            // Source is read from the tick's colour: coral for audio, steel for
            // MIDI, teal for the sync grid, plain ink for a hand-placed one.
            let c: Color = switch event.source {
            case .audio: Sungam.coral
            case .midi: Sungam.steel
            case .sync: Sungam.teal
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

    /// The render range. Everything outside it is washed back with paper, so
    /// what Preview and Render will cover reads at a glance, and the two
    /// edges are marked in steel — the render-chain colour.
    private func drawInOut(_ ctx: GraphicsContext, size: CGSize) {
        guard model.inPoint != nil || model.outPoint != nil else { return }
        let lo = model.inPoint ?? 0
        let hi = model.outPoint ?? duration
        let xl = x(lo, size.width), xr = x(hi, size.width)

        if xl > 0 {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: xl, height: size.height)),
                     with: .color(Sungam.paper.opacity(0.72)))
        }
        if xr < size.width {
            ctx.fill(Path(CGRect(x: xr, y: 0, width: size.width - xr, height: size.height)),
                     with: .color(Sungam.paper.opacity(0.72)))
        }

        for (t, label, isIn) in [(model.inPoint, "IN", true), (model.outPoint, "OUT", false)] {
            guard let t else { continue }
            let px = x(t, size.width)
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0))
            line.addLine(to: CGPoint(x: px, y: size.height))
            ctx.stroke(line, with: .color(Sungam.steel), lineWidth: Sungam.borderStrong)
            // A flag on the inside of the range, so the label never sits
            // over the part being thrown away.
            let flagW: Double = isIn ? 22 : 28
            let flag = CGRect(x: isIn ? px : px - flagW, y: 0, width: flagW, height: 13)
            ctx.fill(Path(flag), with: .color(Sungam.steel))
            ctx.draw(Text(label)
                        .font(Sungam.mono(Sungam.text2xs, weight: .bold))
                        .foregroundStyle(Sungam.paper),
                     at: CGPoint(x: flag.midX, y: flag.midY), anchor: .center)
        }
    }

    private func drawPlayhead(_ ctx: GraphicsContext, size: CGSize) {
        let px = x(model.timelinePlayheadTime, size.width)
        var path = Path()
        path.move(to: CGPoint(x: px, y: 0))
        path.addLine(to: CGPoint(x: px, y: size.height))
        ctx.stroke(path, with: .color(model.isArmed ? Sungam.amber : Sungam.ink85),
                   lineWidth: model.isArmed ? Sungam.borderStrong : Sungam.hairline)
    }
}
