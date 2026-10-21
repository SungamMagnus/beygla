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
    func duration(for e: TriggerEvent) -> Double {
        switch self {
        case .bitstream(let r): return r.duration(for: e)
        case .vector(let r): return r.duration(for: e)
        }
    }
    func hasOwnLength(_ e: TriggerEvent) -> Bool {
        switch self {
        case .bitstream(let r): return r.hasOwnLength(e)
        case .vector(let r): return r.hasOwnLength(e)
        }
    }
    var resetAfter: Bool {
        switch self {
        case .bitstream(let r): return r.resetAfter
        case .vector(let r): return r.resetAfter
        }
    }
}

/// Waveform and onset curve on top, one lane per enabled effect underneath.
///
/// The lanes are the point of the view. Everything the render will do is
/// visible here — each tick is a trigger, each solid bar is frames that will
/// actually be rewritten. Drag a bar's end to give that span its own length;
/// right-click a tick or a bar to remove it.
struct TimelineView: View {
    @EnvironmentObject var model: AppModel

    private enum Marker { case inPoint, outPoint }
    /// An in or out flag being dragged.
    @State private var markerDrag: Marker?
    /// Whether the pointer is over something that drags sideways — a flag
    /// or a bar's end — and so shows the resize cursor.
    @State private var hoveringResize = false
    /// One of a lane's own triggers being dragged.
    @State private var triggerDrag: UUID?
    private typealias Ref = AppModel.BlockRef
    /// Which end of a block a trim drags.
    private enum Trim { case start, end }
    /// One block's start or end being dragged, and where the block stood
    /// when the drag began.
    @State private var trimDrag: (ref: Ref, edit: Trim, start: Double, end: Double,
                                  hasLength: Bool, detached: Bool)?
    /// One block in a move: where it stood when the drag began.
    private struct MoveItem {
        var ref: Ref
        let start: Double
        let end: Double
        let hasLength: Bool
        var detached: Bool
    }
    /// Every selected block moving together, and the time under the pointer
    /// when the drag began, so each keeps its place relative to the grip.
    @State private var moveDrag: (items: [MoveItem], grab: Double)?
    /// A box being dragged out over the lanes; the blocks it touches are
    /// selected, added to what was already selected if Shift or ⌘ was held.
    @State private var marquee: (from: CGPoint, to: CGPoint, base: Set<Ref>)?

    /// The waveform track: shorter than it was, now that triggers have a
    /// track of their own beneath it.
    private let waveH: Double = 60
    /// The Triggers track, between the waveform and the effect lanes.
    private var trigY: Double { waveH + 4 }
    private let trigH: Double = 30
    private let rowH: Double = 20
    /// The name column on the left: each lane's name, colour and arrow, and
    /// the place to click to open or close it. Time starts to its right, so
    /// names never sit on top of blocks.
    private let gutter: Double = 96
    /// An open lane: a header strip to click closed, and a body tall enough
    /// that a trigger's height can stand for its strength.
    private let openH: Double = 46
    private let headerH: Double = 14
    private let gap: Double = 10

    private var duration: Double { max(model.info?.duration ?? 0, 0.001) }
    private var lanes: [LaneRule] {
        model.rules.filter(\.enabled).map(LaneRule.bitstream)
            + model.vectorRules.filter(\.enabled).map(LaneRule.vector)
    }
    private var laneY: Double { trigY + trigH + 6 }

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
                    let secondsPerPoint = visibleDuration / max(w - gutter, 1)
                    // The timeline moves with the fingers, as a scroll view
                    // does: AppKit's delta already follows the system's
                    // natural-scrolling setting, so the content moves by
                    // it and the window into time moves the opposite way.
                    model.panTimeline(bySeconds: -deltaX * secondsPerPoint)
                },
                onRightClick: { p in contextItems(at: p, width: w) }
            ) {
                Canvas { ctx, size in
                    // Everything on the time axis is clipped to the right of
                    // the name column; the column is drawn over it.
                    var timeline = ctx
                    timeline.clip(to: Path(CGRect(x: gutter, y: 0,
                                                  width: max(0, size.width - gutter), height: size.height)))
                    drawGrid(timeline, size: size)
                    drawWaveform(timeline, size: size)
                    drawFlux(timeline, size: size)
                    drawLanes(timeline, size: size)
                    drawTriggers(timeline, size: size)
                    drawInOut(timeline, size: size)
                    drawPlayhead(timeline, size: size)
                    drawGutter(ctx, size: size)
                    drawMarquee(ctx)
                }
                .contentShape(Rectangle())
                // One tap gesture, reading the click count AppKit attaches to
                // the mouse event — so a double-click is exactly what the
                // system's double-click speed says it is. A separate
                // double-tap gesture made SwiftUI hold every single click
                // back; counting clicks by hand got the speed wrong.
                .onTapGesture { p in click(at: p, width: w) }
                // A click is a zero-distance drag, so a drag that accepts one
                // would swallow every tap before either tap gesture saw it.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { g in
                            // A drag that starts on a flag moves that flag and
                            // nothing else — checked before anything else.
                            if markerDrag == nil, trimDrag == nil, moveDrag == nil,
                               marquee == nil, triggerDrag == nil,
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
                            beginDrag(at: g.startLocation, width: w)
                            let t = time(at: g.location.x, width: w)
                            if let id = triggerDrag, let slot = slot(at: g.startLocation.y) {
                                model.moveTrigger(id, to: t - slot.rule.offset,
                                                  strength: strength(at: g.location.y, in: slot))
                            } else if trimDrag != nil {
                                applyTrim(to: t)
                            } else if moveDrag != nil {
                                applyMove(to: t)
                            } else if let m = marquee {
                                marquee = (m.from, g.location, m.base)
                                model.selectedBlocks = m.base.union(blocksTouching(m.from, g.location, width: w))
                            } else if g.startLocation.y < trigY {
                                model.seek(to: t)
                            }
                        }
                        .onEnded { _ in
                            markerDrag = nil
                            triggerDrag = nil
                            trimDrag = nil
                            moveDrag = nil
                            marquee = nil
                        }
                )
                .onContinuousHover { phase in
                    let over: Bool
                    if case .active(let p) = phase {
                        over = marker(at: p, width: w) != nil || edge(at: p, width: w) != nil
                    } else { over = false }
                    if over != hoveringResize {
                        hoveringResize = over
                        if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                }
                .overlay(alignment: .topLeading) { status }
            }
        }
        .frame(height: height)
        .overlay(Rectangle().stroke(Sungam.ink28, lineWidth: Sungam.hairline))
    }

    private var additive: Bool {
        let m = NSEvent.modifierFlags
        return m.contains(.shift) || m.contains(.command)
    }

    private func click(at p: CGPoint, width w: Double) {
        let clicks = NSApp.currentEvent?.clickCount ?? 1
        // The name column: anywhere in a lane's cell opens or closes it.
        if Double(p.x) < gutter {
            if clicks == 1, let slot = slot(at: p.y) { model.toggleLane(slot.rule.id) }
            return
        }
        if marker(at: p, width: w) != nil { return }

        if Double(p.y) < trigY {
            // The waveform only scrubs. It used to place a trigger on a
            // double-click too, which made them appear unasked for.
            if !additive { model.selectedBlocks.removeAll() }
            model.seek(to: time(at: p.x, width: w))
            return
        }
        if Double(p.y) < laneY {
            // The Triggers track works like an effect lane: a click on a
            // trigger selects it, on empty space places one (or, with
            // something selected, only lets go of the selection).
            if let e = sharedTrigger(at: p, width: w) {
                let ref = Ref(eventID: e.id, ruleID: AppModel.triggerTrack)
                if additive {
                    if model.selectedBlocks.contains(ref) { model.selectedBlocks.remove(ref) }
                    else { model.selectedBlocks.insert(ref) }
                } else {
                    model.selectedBlocks = [ref]
                }
            } else if clicks == 1 {
                if !model.selectedBlocks.isEmpty && !additive {
                    model.selectedBlocks.removeAll()
                } else {
                    let id = model.addManualTrigger(at: time(at: p.x, width: w),
                                                    strength: triggerStrength(at: p.y))
                    model.selectedBlocks = [Ref(eventID: id, ruleID: AppModel.triggerTrack)]
                }
            }
            return
        }
        // A click on a block selects it; with Shift or ⌘ it joins (or
        // leaves) the selection instead.
        if let b = block(at: p, width: w) {
            let ref = Ref(eventID: b.event.id, ruleID: b.rule.id)
            if additive {
                if model.selectedBlocks.contains(ref) { model.selectedBlocks.remove(ref) }
                else { model.selectedBlocks.insert(ref) }
            } else {
                model.selectedBlocks = [ref]
            }
            return
        }
        guard let slot = slot(at: p.y) else { model.selectedBlocks.removeAll(); return }
        // Only the first click of a double-click acts, so one double-click
        // never places two triggers.
        guard clicks == 1 else { return }
        if !slot.open || Double(p.y) < slot.y + headerH {
            // A collapsed lane or an open lane's header strip opens or
            // closes it.
            model.toggleLane(slot.rule.id)
        } else if !model.selectedBlocks.isEmpty && !additive {
            // With blocks selected, a click on empty space only lets go of
            // them — placing a trigger as well is what made them appear
            // when all you meant was to deselect.
            model.selectedBlocks.removeAll()
        } else {
            // On empty space in an open lane: a trigger for that effect
            // alone, as strong as the click is high.
            let id = model.addTrigger(for: slot.rule.id,
                                      at: time(at: p.x, width: w) - slot.rule.offset,
                                      strength: strength(at: p.y, in: slot))
            model.selectedBlocks = [Ref(eventID: id, ruleID: slot.rule.id)]
        }
    }

    /// Decide, once per drag, what it is: in order, an open lane's own
    /// trigger handle (time and strength), a block's edge (trim), a block's
    /// body (move every selected block), or empty lane space (box-select).
    private func beginDrag(at p: CGPoint, width w: Double) {
        guard triggerDrag == nil, trimDrag == nil, moveDrag == nil, marquee == nil,
              Double(p.x) >= gutter else { return }
        if Double(p.y) >= trigY && Double(p.y) < laneY,
           let e = sharedTrigger(at: p, width: w) {
            // A trigger on the Triggers track drags like a block: alone if
            // it was not selected, with the whole selection if it was.
            let ref = Ref(eventID: e.id, ruleID: AppModel.triggerTrack)
            if !model.selectedBlocks.contains(ref) {
                model.selectedBlocks = additive ? model.selectedBlocks.union([ref]) : [ref]
            }
            moveDrag = (moveItems(), time(at: p.x, width: w))
        } else if let slot = slot(at: p.y), slot.open, let id = ownHandle(at: p, in: slot, width: w) {
            triggerDrag = id
            model.selectedBlocks = [Ref(eventID: id, ruleID: slot.rule.id)]
        } else if let (b, isStart) = edge(at: p, width: w) {
            let ref = Ref(eventID: b.event.id, ruleID: b.rule.id)
            trimDrag = (ref, isStart ? .start : .end, b.start, b.end, b.rule.hasOwnLength(b.event), false)
            model.selectedBlocks = [ref]
        } else if let b = block(at: p, width: w) {
            let ref = Ref(eventID: b.event.id, ruleID: b.rule.id)
            // Dragging a block outside the selection picks it alone (or adds
            // it, with Shift or ⌘); dragging one inside moves them all.
            if !model.selectedBlocks.contains(ref) {
                model.selectedBlocks = additive ? model.selectedBlocks.union([ref]) : [ref]
            }
            moveDrag = (moveItems(), time(at: p.x, width: w))
        } else if Double(p.y) >= trigY {
            marquee = (p, p, additive ? model.selectedBlocks : [])
        }
    }

    /// Every selected block and trigger, as it stands now, ready to move.
    private func moveItems() -> [MoveItem] {
        model.selectedBlocks.compactMap { r -> MoveItem? in
            guard let e = model.events.first(where: { $0.id == r.eventID }) else { return nil }
            if r.ruleID == AppModel.triggerTrack {
                return MoveItem(ref: r, start: e.time, end: e.time, hasLength: false, detached: true)
            }
            guard let rule = lanes.first(where: { $0.id == r.ruleID }) else { return nil }
            let start = e.time + rule.offset
            return MoveItem(ref: r, start: start, end: start + rule.duration(for: e),
                            hasLength: rule.hasOwnLength(e), detached: false)
        }
    }

    /// The first time a shared trigger's block is moved or has its start
    /// trimmed it becomes a trigger of that effect's own, so nothing moves on
    /// any other lane. The selection follows it to its new id.
    private func detachIfShared(_ ref: Ref, length: Double?) -> Ref {
        guard let e = model.events.first(where: { $0.id == ref.eventID }) else { return ref }
        let id = model.detach(e, for: ref.ruleID, length: length)
        let new = Ref(eventID: id, ruleID: ref.ruleID)
        if new != ref {
            model.selectedBlocks.remove(ref)
            model.selectedBlocks.insert(new)
        }
        return new
    }

    private func applyTrim(to t: Double) {
        guard var d = trimDrag, let rule = lanes.first(where: { $0.id == d.ref.ruleID }) else { return }
        let frame = 1 / max(model.info?.frameRate ?? 30, 1)
        switch d.edit {
        case .end:
            // A length alone needs no detaching: a shared trigger keeps a
            // per-effect length of its own.
            guard let e = model.events.first(where: { $0.id == d.ref.eventID }) else { return }
            model.setSpanLength(max(t, d.start + frame) - d.start, for: e, on: d.ref.ruleID)
        case .start:
            if !d.detached {
                d.ref = detachIfShared(d.ref, length: d.end - d.start)
                d.detached = true
            }
            let start = min(t, d.end - frame)
            model.setTriggerSpan(d.ref.eventID, time: start - rule.offset, length: d.end - start)
        }
        trimDrag = d
    }

    private func applyMove(to t: Double) {
        guard var m = moveDrag else { return }
        let delta = t - m.grab
        for i in m.items.indices {
            // A trigger itself moves for every effect it reaches.
            if m.items[i].ref.ruleID == AppModel.triggerTrack {
                model.moveSharedTrigger(m.items[i].ref.eventID, to: m.items[i].start + delta)
                continue
            }
            guard let rule = lanes.first(where: { $0.id == m.items[i].ref.ruleID }) else { continue }
            let len = m.items[i].hasLength ? m.items[i].end - m.items[i].start : nil
            if !m.items[i].detached {
                m.items[i].ref = detachIfShared(m.items[i].ref, length: len)
                m.items[i].detached = true
            }
            model.setTriggerSpan(m.items[i].ref.eventID,
                                 time: m.items[i].start + delta - rule.offset, length: len)
        }
        moveDrag = m
    }

    /// Every block the box between two points touches.
    private func blocksTouching(_ a: CGPoint, _ b: CGPoint, width: Double) -> Set<Ref> {
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                         width: abs(a.x - b.x), height: abs(a.y - b.y))
        var hit: Set<Ref> = []
        if box.maxY >= trigY && box.minY < trigY + trigH {
            for e in model.events where e.ruleID == nil {
                let px = x(e.time, width)
                if px >= Double(box.minX) - 3 && px <= Double(box.maxX) + 3 {
                    hit.insert(Ref(eventID: e.id, ruleID: AppModel.triggerTrack))
                }
            }
        }
        for slot in slots {
            let area = slot.open ? bodyRect(slot, width) : laneRect(slot, width)
            for b in blocks(in: slot) {
                let r = CGRect(x: x(b.start, width), y: area.minY,
                               width: max(2, x(b.end, width) - x(b.start, width)), height: area.height)
                if r.intersects(box) { hit.insert(Ref(eventID: b.event.id, ruleID: b.rule.id)) }
            }
        }
        return hit
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
        gutter + (width - gutter) * (t - visibleStart) / visibleDuration
    }

    private func time(at x: CGFloat, width: Double) -> Double {
        let t = visibleStart + (Double(x) - gutter) / max(width - gutter, 1) * visibleDuration
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

    /// An open lane below its header strip, which its blocks fill.
    private func bodyRect(_ slot: LaneSlot, _ width: Double) -> CGRect {
        CGRect(x: 0, y: slot.y + headerH, width: width, height: slot.h - headerH - 2)
    }

    /// A shared trigger's marker on the Triggers track under a point.
    private func sharedTrigger(at p: CGPoint, width: Double) -> TriggerEvent? {
        guard Double(p.x) >= gutter, Double(p.y) >= trigY, Double(p.y) < trigY + trigH else { return nil }
        let px = Double(p.x)
        return model.events
            .filter { $0.ruleID == nil }
            .map { ($0, abs(x($0.time, width) - px)) }
            .filter { $0.1 <= 5 }
            .min { $0.1 < $1.1 }?.0
    }

    /// How strong a trigger placed at this height on the Triggers track is.
    private func triggerStrength(at y: CGFloat) -> Double {
        let bottom = trigY + trigH - 3, room = trigH - 9
        return (bottom - Double(y)) / room
    }

    /// One block on a lane: the trigger, its effect, and where it runs.
    private struct Block {
        let event: TriggerEvent
        let rule: LaneRule
        let start: Double
        let end: Double
    }

    private func blocks(in slot: LaneSlot) -> [Block] {
        let rule = slot.rule
        return model.events.filter { rule.matches($0) }.map { e in
            let start = e.time + rule.offset
            return Block(event: e, rule: rule, start: start, end: start + rule.duration(for: e))
        }
    }

    /// The block under a point. Where blocks overlap, the one starting
    /// nearest the pointer wins.
    private func block(at p: CGPoint, width: Double) -> Block? {
        guard Double(p.x) >= gutter, let slot = slot(at: p.y) else { return nil }
        if slot.open && Double(p.y) < slot.y + headerH { return nil }
        let px = Double(p.x)
        return blocks(in: slot)
            .filter { px >= x($0.start, width) - 2 && px <= x($0.end, width) + 2 }
            .min { abs(x($0.start, width) - px) < abs(x($1.start, width) - px) }
    }

    /// A block's start or end edge under a point (true for the start). A
    /// selected block's edges win, so a trim on a busy lane takes the block
    /// you picked; otherwise only end edges grab, leaving a click near a
    /// block's start free to select or move it.
    private func edge(at p: CGPoint, width: Double) -> (Block, Bool)? {
        guard Double(p.x) >= gutter, let slot = slot(at: p.y) else { return nil }
        if slot.open && Double(p.y) < slot.y + headerH { return nil }
        let px = Double(p.x)
        let all = blocks(in: slot)
        for b in all where model.selectedBlocks.contains(Ref(eventID: b.event.id, ruleID: b.rule.id)) {
            if abs(x(b.start, width) - px) <= 4 { return (b, true) }
            if abs(x(b.end, width) - px) <= 4 { return (b, false) }
        }
        return all.map { ($0, abs(x($0.end, width) - px)) }
            .filter { $0.1 <= 4 }
            .min { $0.1 < $1.1 }
            .map { ($0.0, false) }
    }

    /// An open lane's own-trigger handle — the square standing at the
    /// trigger's strength — under a point.
    private func ownHandle(at p: CGPoint, in slot: LaneSlot, width: Double) -> UUID? {
        let body = bodyRect(slot, width)
        return model.events
            .filter { $0.ruleID == slot.rule.id }
            .first { e in
                let px = x(e.time + slot.rule.offset, width) + 1.5
                let top = body.maxY - body.height * e.strength
                return abs(px - Double(p.x)) <= 6 && abs(top - Double(p.y)) <= 6
            }?.id
    }

    /// The trigger a right-click is about: on a lane, the one whose bar (or
    /// stem) is under the pointer; above the lanes, the nearest tick.
    private func contextItems(at p: CGPoint, width: Double) -> [(title: String, action: () -> Void)] {
        guard Double(p.x) >= gutter else { return [] }
        let px = Double(p.x)
        func when(_ e: TriggerEvent) -> String { String(format: "%.2fs", e.time) }

        if Double(p.y) < trigY { return [] }
        if Double(p.y) < laneY {
            guard let e = sharedTrigger(at: p, width: width) else { return [] }
            var items: [(title: String, action: () -> Void)] = []
            let n = model.selectedBlocks.count
            if n > 1, model.selectedBlocks.contains(Ref(eventID: e.id, ruleID: AppModel.triggerTrack)) {
                items.append(("Delete \(n) selected", { model.deleteSelectedBlocks() }))
                items.append(("-", {}))
            }
            items.append(("Delete trigger at \(when(e))", { model.deleteTrigger(e.id) }))
            return items
        }

        guard let slot = slot(at: p.y) else { return [] }
        let rule = slot.rule
        guard let e = model.events
            .filter({ rule.matches($0) })
            .map({ e -> (TriggerEvent, Double) in
                let x0 = x(e.time + rule.offset, width) - 4
                let x1 = x(e.time + rule.offset + rule.duration(for: e), width) + 4
                let d = px < x0 ? x0 - px : px > x1 ? px - x1 : 0
                return (e, d)
            })
            .filter({ $0.1 == 0 })
            .min(by: { abs(x($0.0.time, width) - px) < abs(x($1.0.time, width) - px) })?.0
        else { return [] }

        var items: [(title: String, action: () -> Void)] = []
        let n = model.selectedBlocks.count
        if n > 1, model.selectedBlocks.contains(Ref(eventID: e.id, ruleID: rule.id)) {
            items.append(("Delete \(n) selected blocks", { model.deleteSelectedBlocks() }))
            items.append(("-", {}))
        }
        if e.ruleID == rule.id {
            items.append(("Delete trigger at \(when(e))", { model.removeTrigger(e.id) }))
        } else {
            items.append(("Remove from \(rule.displayName)", { model.excludeTrigger(e, from: rule.id) }))
            items.append(("Delete trigger at \(when(e)) for every effect", { model.deleteTrigger(e.id) }))
        }
        if rule.hasOwnLength(e) {
            items.append(("-", {}))
            items.append(("Reset length to \(String(format: "%.0f", rule.duration * 1000)) ms",
                          { model.setSpanLength(nil, for: e, on: rule.id) }))
        }
        return items
    }

    private func strength(at y: CGFloat, in slot: LaneSlot) -> Double {
        let body = bodyRect(slot, 1)
        return (body.maxY - Double(y)) / max(body.height, 1)
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

    private var selectedTriggers: Set<UUID> {
        Set(model.selectedBlocks.filter { $0.ruleID == AppModel.triggerTrack }.map(\.eventID))
    }

    private func drawLanes(_ ctx: GraphicsContext, size: CGSize) {
        guard !lanes.isEmpty else {
            ctx.draw(Text("NO EFFECTS ENABLED")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink38),
                     at: CGPoint(x: gutter + 8, y: laneY + 8), anchor: .leading)
            return
        }

        for slot in slots {
            let rule = slot.rule
            let rect = laneRect(slot, size.width)
            let color = rule.color
            let dark = color.darker()

            // The lane itself.
            ctx.fill(Path(rect), with: .color(Sungam.ink.opacity(slot.open ? 0.06 : 0.035)))
            ctx.fill(Path(rect), with: .color(color.opacity(0.08)))

            // Blocks: the frames this rule will actually rewrite. Collapsed
            // they sit inside the row; open they fill the body, shaded by
            // the trigger's strength. Each starts with a darker tab, so where
            // a slot begins reads even where blocks butt up against each
            // other. A block with a length of its own is outlined; an effect
            // that resets after itself ends each one with a full-height cut;
            // with Smear set, a faint tail shows how long the damage lingers.
            let area = slot.open ? bodyRect(slot, size.width) : rect
            let barY = area.minY + (slot.open ? 1 : 3)
            let barH = area.height - (slot.open ? 2 : 6)
            if slot.open {
                var header = Path()
                header.move(to: CGPoint(x: 0, y: area.minY))
                header.addLine(to: CGPoint(x: size.width, y: area.minY))
                ctx.stroke(header, with: .color(Sungam.ink13), lineWidth: Sungam.hairline)
            }
            for event in model.events where rule.matches(event) {
                let len = rule.duration(for: event)
                let x0 = x(event.time + rule.offset, size.width)
                let x1 = x(event.time + rule.offset + len, size.width)
                if rule.resetAfter {
                    var cut = Path()
                    cut.move(to: CGPoint(x: x1, y: rect.minY))
                    cut.addLine(to: CGPoint(x: x1, y: rect.maxY))
                    ctx.stroke(cut, with: .color(Sungam.ink70), lineWidth: 1.5)
                } else if let smear = model.smear, smear > 0 {
                    let x2 = x(event.time + rule.offset + len + smear, size.width)
                    ctx.fill(Path(CGRect(x: x1, y: barY + barH * 0.3,
                                         width: max(1, x2 - x1), height: barH * 0.4)),
                             with: .color(color.opacity(0.28)))
                }
                let bar = CGRect(x: x0, y: barY, width: max(1.5, x1 - x0), height: barH)
                let shade = slot.open ? 0.35 + 0.65 * event.strength : 1
                ctx.fill(Path(bar), with: .color(color.opacity(shade)))
                ctx.fill(Path(CGRect(x: x0, y: barY, width: min(3, bar.width), height: barH)),
                         with: .color(dark))
                if rule.hasOwnLength(event) {
                    ctx.stroke(Path(bar.insetBy(dx: -1, dy: -1)), with: .color(Sungam.ink85),
                               lineWidth: Sungam.hairline)
                }
                // A block fired by a selected trigger: a dashed outline, so
                // selecting a trigger shows everything it sets off.
                if selectedTriggers.contains(event.id) {
                    ctx.stroke(Path(bar.insetBy(dx: -1.5, dy: -1.5)), with: .color(Sungam.ink85),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                // The selected block: a bright outline and a grip at each
                // end, the handles its start and end are dragged by.
                if model.selectedBlocks.contains(Ref(eventID: event.id, ruleID: rule.id)) {
                    ctx.stroke(Path(bar.insetBy(dx: -1.5, dy: -1.5)), with: .color(Sungam.ink),
                               lineWidth: 1.5)
                    for gx in [x0, x1] {
                        ctx.fill(Path(CGRect(x: gx - 2, y: barY - 2, width: 4, height: barH + 4)),
                                 with: .color(Sungam.ink))
                    }
                }
            }

            if slot.open { drawOwnTriggers(ctx, slot: slot, size: size) }

            if slot.open {
                ctx.draw(Text("CLICK TO ADD A TRIGGER · HIGHER IS STRONGER")
                            .font(Sungam.mono(Sungam.text2xs))
                            .foregroundStyle(Sungam.ink38),
                         at: CGPoint(x: size.width - 6, y: slot.y + headerH / 2), anchor: .trailing)
            }
        }
    }

    /// An open lane's own triggers: a handle at the start of each block,
    /// standing as high as the trigger is strong, to grab and drag.
    private func drawOwnTriggers(_ ctx: GraphicsContext, slot: LaneSlot, size: CGSize) {
        let body = bodyRect(slot, size.width)
        let dark = slot.rule.color.darker()
        for event in model.events where event.ruleID == slot.rule.id {
            let px = x(event.time + slot.rule.offset, size.width)
            let top = body.maxY - body.height * event.strength
            let dragging = event.id == triggerDrag
            var stem = Path()
            stem.move(to: CGPoint(x: px + 1.5, y: top))
            stem.addLine(to: CGPoint(x: px + 1.5, y: body.maxY))
            ctx.stroke(stem, with: .color(Sungam.ink85), lineWidth: dragging ? 2 : 1)
            let s: Double = dragging ? 9 : 7
            let handle = CGRect(x: px + 1.5 - s / 2, y: top - s / 2, width: s, height: s)
            ctx.fill(Path(handle), with: .color(dark))
            ctx.stroke(Path(handle), with: .color(Sungam.ink85), lineWidth: Sungam.hairline)
        }
    }

    /// The Triggers track. Each shared trigger is a stem as tall as it is
    /// strong, topped with a square in its source's colour — coral for audio,
    /// steel for MIDI, teal for the sync grid, ink for one placed by hand —
    /// and a faint line up through the waveform to show what it caught.
    private func drawTriggers(_ ctx: GraphicsContext, size: CGSize) {
        let track = CGRect(x: 0, y: trigY, width: size.width, height: trigH)
        ctx.fill(Path(track), with: .color(Sungam.ink.opacity(0.05)))
        let bottom = track.maxY - 3, room = trigH - 9
        for event in model.events where event.ruleID == nil {
            let px = x(event.time, size.width)
            let c: Color = switch event.source {
            case .audio: Sungam.coral
            case .midi: Sungam.steel
            case .sync: Sungam.teal
            case .manual: Sungam.ink70
            }
            var guide = Path()
            guide.move(to: CGPoint(x: px, y: 0))
            guide.addLine(to: CGPoint(x: px, y: waveH))
            ctx.stroke(guide, with: .color(c.opacity(0.25)), lineWidth: Sungam.hairline)

            let top = bottom - room * event.strength
            var stem = Path()
            stem.move(to: CGPoint(x: px, y: top))
            stem.addLine(to: CGPoint(x: px, y: bottom))
            ctx.stroke(stem, with: .color(c.darker(0.3)), lineWidth: 1.5)
            let selected = model.selectedBlocks.contains(Ref(eventID: event.id, ruleID: AppModel.triggerTrack))
            let sq: Double = selected ? 9 : 7
            let mark = CGRect(x: px - sq / 2, y: top - sq / 2, width: sq, height: sq)
            ctx.fill(Path(mark), with: .color(c))
            if selected {
                ctx.stroke(Path(mark.insetBy(dx: -2, dy: -2)), with: .color(Sungam.ink), lineWidth: 1.5)
            }
            if event.pinned {
                // Moved by hand: a small notch under the stem.
                ctx.fill(Path(CGRect(x: px - 3, y: bottom, width: 6, height: 1.5)), with: .color(c))
            }
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

    /// The name column: one cell per lane with its arrow, colour and name in
    /// full ink, a little brighter when open, and below the name what is
    /// special about it — RESETS, or how many triggers of its own it has.
    private func drawGutter(_ ctx: GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: gutter, height: size.height)),
                 with: .color(Sungam.paper))
        ctx.fill(Path(CGRect(x: 0, y: trigY, width: gutter, height: size.height - trigY)),
                 with: .color(Sungam.ink.opacity(0.04)))
        ctx.draw(Text("AUDIO")
                    .font(Sungam.mono(Sungam.text2xs, weight: .bold))
                    .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.ink45),
                 at: CGPoint(x: 10, y: waveH / 2), anchor: .leading)
        let shared = model.events.filter { $0.ruleID == nil }.count
        ctx.fill(Path(CGRect(x: 0, y: trigY, width: 3, height: trigH)), with: .color(Sungam.coral))
        ctx.draw(Text("TRIGGERS")
                    .font(Sungam.mono(Sungam.textXs, weight: .bold))
                    .foregroundStyle(Sungam.ink),
                 at: CGPoint(x: 10, y: trigY + trigH / 2 - 5), anchor: .leading)
        ctx.draw(Text("\(shared)")
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.coral),
                 at: CGPoint(x: 10, y: trigY + trigH / 2 + 8), anchor: .leading)
        for slot in slots {
            let rule = slot.rule
            let cell = CGRect(x: 0, y: slot.y, width: gutter, height: slot.h - 2)
            if slot.open {
                ctx.fill(Path(cell), with: .color(rule.color.opacity(0.14)))
            }
            // A bar of the effect's colour down the cell's left edge.
            ctx.fill(Path(CGRect(x: 0, y: cell.minY, width: 3, height: cell.height)),
                     with: .color(rule.color))
            let rowMid = slot.open ? slot.y + headerH / 2 + 1 : cell.midY
            ctx.draw(Text(slot.open ? "▾" : "▸")
                        .font(Sungam.mono(Sungam.textSm, weight: .bold))
                        .foregroundStyle(Sungam.ink85),
                     at: CGPoint(x: 10, y: rowMid), anchor: .leading)
            ctx.draw(Text(rule.displayName.uppercased())
                        .font(Sungam.mono(Sungam.textXs, weight: .bold))
                        .foregroundStyle(Sungam.ink),
                     at: CGPoint(x: 22, y: rowMid), anchor: .leading)
            if slot.open {
                let own = model.events.filter { $0.ruleID == rule.id }.count
                let notes = [rule.resetAfter ? "RESETS" : nil, own > 0 ? "\(own) OWN" : nil]
                    .compactMap { $0 }.joined(separator: " · ")
                if !notes.isEmpty {
                    ctx.draw(Text(notes)
                                .font(Sungam.mono(Sungam.text2xs))
                                .foregroundStyle(rule.color),
                             at: CGPoint(x: 22, y: rowMid + 14), anchor: .leading)
                }
            } else if rule.resetAfter {
                ctx.draw(Text("↺")
                            .font(Sungam.mono(Sungam.textXs, weight: .bold))
                            .foregroundStyle(rule.color),
                         at: CGPoint(x: gutter - 8, y: rowMid), anchor: .trailing)
            }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: cell.maxY + 1))
            line.addLine(to: CGPoint(x: gutter, y: cell.maxY + 1))
            ctx.stroke(line, with: .color(Sungam.ink13), lineWidth: Sungam.hairline)
        }
        var edge = Path()
        edge.move(to: CGPoint(x: gutter, y: 0))
        edge.addLine(to: CGPoint(x: gutter, y: size.height))
        ctx.stroke(edge, with: .color(Sungam.ink22), lineWidth: Sungam.hairline)
    }

    private func drawMarquee(_ ctx: GraphicsContext) {
        guard let m = marquee else { return }
        let box = CGRect(x: min(m.from.x, m.to.x), y: min(m.from.y, m.to.y),
                         width: abs(m.from.x - m.to.x), height: abs(m.from.y - m.to.y))
        ctx.fill(Path(box), with: .color(Sungam.ink.opacity(0.08)))
        ctx.stroke(Path(box), with: .color(Sungam.ink70),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
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
