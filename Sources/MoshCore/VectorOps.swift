import Foundation

/// The second family of effects: rewriting the motion vectors *inside* a
/// frame, rather than reordering or dropping whole frames.
///
/// Everything in MoshEngine treats a compressed frame as an opaque blob and
/// only ever moves, holds or deletes whole ones. That is deliberately as far
/// as byte surgery on an AVI can reach — a frame's payload is an entropy-coded
/// bitstream, not an array anything can index into. Motion vectors are
/// different: FFglitch's `ffedit` decodes just far enough to expose them as a
/// plain JSON array, runs a script over that array, and re-encodes the
/// result. That is a real decode/edit/re-encode pass, not byte surgery, which
/// is why it needs its own tool (`FFglitchTool`) and its own pipeline stage
/// rather than slotting into `MoshEngine`.
///
/// Ported from the FFglitch scripts in
/// [Datamosher Pro](https://github.com/Akascape/Datamosher-Pro)
/// (`DatamoshLib/FFG_effects/jscripts/`). Each of those scripts carried its
/// own random-threshold self-triggering ("do this for N frames if a coin flip
/// exceeds 95"), because the tool they were written for had no other way to
/// place an effect in time. Beygla already has one — the same trigger, rule
/// and region machinery that drives `MoshOpKind` — so that scaffolding is
/// dropped and only the vector transform itself is kept. `Buffer.js`'s
/// feedback behaviour survives as `delay`'s `feedback` parameter rather than
/// as a separate effect, since the two scripts differ by one line.
public enum VectorOpKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sink, stop, invertReverse, mirror, vibrate, zoom, slamZoom, shear, delay, shift, noise

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sink: return "Sink"
        case .stop: return "Stop"
        case .invertReverse: return "Invert"
        case .mirror: return "Mirror"
        case .vibrate: return "Vibrate"
        case .zoom: return "Zoom"
        case .slamZoom: return "Slam Zoom"
        case .shear: return "Shear"
        case .delay: return "Delay"
        case .shift: return "Shift"
        case .noise: return "Noise"
        }
    }

    /// Which DMP script(s) this ports, so the mapping is checkable.
    public var source: String {
        switch self {
        case .sink: return "Sink.js"
        case .stop: return "Stop.js"
        case .invertReverse: return "Invert-Reverse.js"
        case .mirror: return "Mirror.js"
        case .vibrate: return "Vibrate.js"
        case .zoom: return "Zoom.js"
        case .slamZoom: return "Slam Zoom.js"
        case .shear: return "Shear.js"
        case .delay: return "Delay.js + Buffer.js"
        case .shift: return "Shift.js"
        case .noise: return "Noise.js"
        }
    }

    public var summary: String {
        switch self {
        case .sink: return "Fast-moving blocks freeze in place"
        case .stop: return "Every block freezes, unconditionally"
        case .invertReverse: return "Motion runs backwards through the frame"
        case .mirror: return "The motion field flips left to right"
        case .vibrate: return "Every block shudders at random"
        case .zoom: return "Motion pulls outward from centre"
        case .slamZoom: return "Motion replaced by a pure radial pull"
        case .shear: return "Motion skews diagonally across the frame"
        case .delay: return "Motion answers to a frame from the past"
        case .shift: return "Motion drifts downward like gravity"
        case .noise: return "The stillest blocks convulse instead"
        }
    }

    public var blurb: String {
        switch self {
        case .sink:
            return """
            Leaves slow motion alone and zeroes anything faster than a \
            threshold, so a moving subject's fastest-moving edges freeze while \
            its slow interior keeps tracking. The frozen blocks stay pinned to \
            wherever they were the instant the threshold was crossed. Amount \
            lowers the threshold — higher catches more of the frame.
            """
        case .stop:
            return """
            Zeroes every motion vector in the frame, unconditionally. Unlike \
            Sink there is no threshold: the whole picture's motion goes dead \
            at once, which reads as a much harder cut than a bitstream freeze \
            because the blocks that would have moved are still being \
            re-drawn — they are just being told to stay exactly still.
            """
        case .invertReverse:
            return """
            Negates every vector, so whatever was moving right now moves left \
            by the same amount, and up becomes down. The picture's content \
            keeps updating normally; only the direction motion pushes it is \
            reversed, which reads as the frame's content flowing backwards \
            through itself.
            """
        case .mirror:
            return """
            Reflects the motion field left to right and negates the \
            horizontal component, so the right half of the picture is pushed \
            by a mirror image of what is happening on the left. Symmetric \
            content barely changes; anything asymmetric develops a seam down \
            the middle where the two mismatched motions meet.
            """
        case .vibrate:
            return """
            Adds an independent random offset to every block's vector, every \
            frame. Nothing drifts in one direction — each macroblock shudders \
            on its own axis, which reads as a fine, even static laid over \
            whatever the frame's real motion was doing. Amount sets how far \
            each block can jump.
            """
        case .zoom:
            return """
            Adds an outward radial push to every vector, scaled by how far \
            that block sits from the frame's centre — corners are pushed \
            hardest, the centre barely at all. Stacked on top of the frame's \
            real motion, so a subject already moving still carries on doing \
            so, just with the whole picture also pulling apart from the \
            middle. Negative amount pulls inward instead.
            """
        case .slamZoom:
            return """
            The same radial field as Zoom, but it replaces each vector \
            instead of adding to it — the frame's real motion is discarded \
            entirely and only the outward pull remains. Reads as a much \
            harder, more mechanical zoom with none of the original motion's \
            texture left in it.
            """
        case .shear:
            return """
            Adds a diagonal offset that grows with distance from centre, \
            pushing opposite corners in opposite directions. The picture \
            reads as being dragged across itself on a slant rather than \
            pulled apart symmetrically the way Zoom does.
            """
        case .delay:
            return """
            Replaces each block's vector with the vector that same block had \
            several frames ago, so the picture's motion runs on a tape delay \
            — it answers to what was happening a moment in the past rather \
            than what is happening now. Feedback blends a fraction of the \
            delayed value back into the buffer instead of swapping it \
            outright, which is the difference between a hard echo and a \
            trailing one.
            """
        case .shift:
            return """
            Feeds each block's vertical motion into the next frame's, with a \
            constant added each time — motion that was drifting keeps \
            drifting, and accumulates, the way gravity keeps accelerating \
            something already falling. Reads as the picture sliding downward \
            and picking up speed rather than any one frame's motion looking \
            unusual on its own.
            """
        case .noise:
            return """
            Finds the fastest-moving block in the frame, then multiplies \
            every block moving slower than half that speed by a large \
            factor. It is the inverse of what a glitch usually does: instead \
            of the busy parts of the picture breaking, the parts that were \
            holding still convulse instead.
            """
        }
    }
}

/// One vector effect covering a span of frames, at a given amount. Deliberately
/// the same shape as `MoshOp` — start/length/amount — because it is built by
/// the same `TriggerCompiler` from the same rules and regions; only the
/// engine that consumes it differs.
public struct VectorOp: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: VectorOpKind
    public var startFrame: Int
    public var length: Int
    public var amount: Double
    public var seed: UInt64

    public init(id: UUID = UUID(), kind: VectorOpKind, startFrame: Int, length: Int,
                amount: Double = 0.6, seed: UInt64 = 0x5EED) {
        self.id = id
        self.kind = kind
        self.startFrame = startFrame
        self.length = length
        self.amount = amount
        self.seed = seed
    }

    public var endFrame: Int { startFrame + length }
}

/// A rule that turns trigger events into `VectorOp`s. Mirrors `MoshRule`
/// exactly, down to reusing `ActiveRegion`, so the two families share one
/// mental model even though they render through different engines.
public struct VectorRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var kind: VectorOpKind
    public var source: TriggerSource
    public var note: Int?
    public var band: OnsetBand?
    public var duration: Double
    public var durationJitter: Double
    public var amountFloor: Double
    public var strengthInfluence: Double
    public var probability: Double
    public var offset: Double
    public var activeRegions: [ActiveRegion]

    public init(id: UUID = UUID(), enabled: Bool = true, kind: VectorOpKind,
                source: TriggerSource, note: Int? = nil, band: OnsetBand? = nil,
                duration: Double = 0.3, durationJitter: Double = 0,
                amountFloor: Double = 0.5, strengthInfluence: Double = 0.5,
                probability: Double = 1.0, offset: Double = 0,
                activeRegions: [ActiveRegion] = []) {
        self.id = id
        self.enabled = enabled
        self.kind = kind
        self.source = source
        self.note = note
        self.band = band
        self.duration = duration
        self.durationJitter = durationJitter
        self.amountFloor = amountFloor
        self.strengthInfluence = strengthInfluence
        self.probability = probability
        self.offset = offset
        self.activeRegions = activeRegions
    }

    public func isActive(at time: Double) -> Bool {
        activeRegions.isEmpty || activeRegions.contains { $0.contains(time) }
    }

    public func matches(_ event: TriggerEvent) -> Bool {
        guard enabled else { return false }
        guard isActive(at: event.time) else { return false }
        if event.source == .manual { return true }
        guard source == event.source else { return false }
        if let n = note, event.note != n { return false }
        if let b = band, let eb = event.band, b != eb { return false }
        return true
    }
}

public enum VectorTriggerCompiler {
    /// Compiles events + vector rules into `VectorOp`s. Same shape as
    /// `TriggerCompiler.compile` — kept as a twin rather than a shared generic
    /// so the two op types (and the engines that read them) stay decoupled.
    public static func compile(events: [TriggerEvent], rules: [VectorRule],
                               frameRate: Double, frameCount: Int,
                               seed: UInt64 = 0x5645_4354) -> [VectorOp] {
        var rng = SplitMix64(seed: seed)
        var ops: [VectorOp] = []

        for event in events.sorted(by: { $0.time < $1.time }) {
            for rule in rules where rule.matches(event) {
                if rule.probability < 1.0 {
                    let roll = Double(rng.next() % 10_000) / 10_000.0
                    if roll > rule.probability { continue }
                }

                var duration = rule.duration
                if rule.durationJitter > 0 {
                    let j = (Double(rng.next() % 2_000) / 1_000.0 - 1.0) * rule.durationJitter
                    duration *= max(0.1, 1.0 + j)
                }

                let start = Int(((event.time + rule.offset) * frameRate).rounded())
                let length = max(1, Int((duration * frameRate).rounded()))
                guard start < frameCount else { continue }

                let amount = min(1.0, max(0.0,
                    rule.amountFloor + event.strength * rule.strengthInfluence))

                ops.append(VectorOp(kind: rule.kind,
                                    startFrame: max(0, start),
                                    length: min(length, frameCount - max(0, start)),
                                    amount: amount,
                                    seed: rng.next()))
            }
        }

        return ops
    }
}
