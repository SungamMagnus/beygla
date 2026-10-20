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
/// dropped and only the vector transform itself is kept. `Buffer.js` is
/// folded into `delay` rather than kept as a separate effect.
public enum VectorOpKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sink, stop, invertReverse, mirror, vibrate, zoom, slamZoom, shear, delay, shift, noise

    public var id: String { rawValue }

    /// Whether Amount changes anything. Stop, Invert and Mirror are fixed
    /// transforms of the motion field; the app hides Amount and Velocity for
    /// them rather than offer controls that do nothing.
    public var usesAmount: Bool {
        switch self {
        case .stop, .mirror: return false
        default: return true
        }
    }

    /// Where Amount starts on a new effect. Invert starts fully reversed and
    /// the radial three start pushing outward — their neutral point is 0.5,
    /// so the generic default would have made a new Zoom do nothing.
    public var defaultAmount: Double {
        switch self {
        case .invertReverse: return 1
        case .zoom, .slamZoom, .shear: return 0.8
        default: return 0.5
        }
    }

    /// Effects whose result depends on the seed even with Chance and Jitter
    /// left alone.
    public var isRandom: Bool { self == .vibrate }

    /// Mirror and Vibrate choose which axis they work on.
    public var hasAxis: Bool { self == .mirror || self == .vibrate }
    /// The radial three pull from a centre point that can be moved.
    public var hasCentre: Bool { isBipolar }

    /// Neutral at Amount 0.5 and pulling the other way below it.
    public var isBipolar: Bool {
        switch self {
        case .zoom, .slamZoom, .shear: return true
        default: return false
        }
    }

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
            return "Freezes blocks moving faster than a threshold; slow motion carries on. Amount lowers the threshold."
        case .stop:
            return "Zeroes all motion in the frame: a harder stop than Freeze, because the blocks keep redrawing in place."
        case .invertReverse:
            return "Turns motion around: at full, right becomes left and up becomes down; at half it stops dead; below, it only slows."
        case .mirror:
            return "Mirrors the motion left to right, top to bottom, or both. Symmetric shots barely change; anything else splits along the axis."
        case .vibrate:
            return "Shakes every block at random each frame, like static over the real motion. Amount sets how far; Axis limits which way."
        case .zoom:
            return "Adds an outward pull from the centre point, on top of the real motion. Below 0.5 it pulls inward."
        case .slamZoom:
            return "Like Zoom, but replaces the real motion with the pull: harder and more mechanical."
        case .shear:
            return "Pushes opposite corners in opposite directions, dragging the picture across itself on a slant."
        case .delay:
            return "Each block moves the way it did a few frames earlier. Amount sets how far back; Feedback lets older echoes trail in."
        case .shift:
            return "Motion keeps falling and speeding up, like gravity, so the picture slides the chosen way."
        case .noise:
            return "Makes the stillest blocks convulse instead of the busiest ones. Threshold sets how still counts as still."
        }
    }
}

/// Which way a vector effect works: both axes, across, or up and down.
public enum MotionAxis: String, Codable, CaseIterable, Identifiable, Sendable {
    case both, horizontal, vertical
    public var id: String { rawValue }
    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Which way Shift's motion falls.
public enum MotionDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case down, up, left, right
    public var id: String { rawValue }
    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
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
    /// Position of the rule that made this op in its effect chain. Ops are
    /// applied chain position first, so the order of the effect list is the
    /// order the effects process the frames in — later ones work on what
    /// earlier ones produced, like a rack.
    public var chain: Int = 0
    /// The effect's own settings beyond Amount, in the order its script
    /// function reads them (axis, direction, centre, feedback, threshold).
    public var params: [Double] = []
    /// 0...1: how far Amount fades toward nothing by the end of the span.
    public var decay: Double = 0

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
    /// See `MoshRule.seed`. Vibrate shakes with it; Chance and Jitter roll
    /// with it.
    public var seed: UInt32 = 1
    /// 0...1: how far Amount fades toward nothing across the span, so the
    /// effect dies away instead of switching off at its end.
    public var decay: Double = 0
    /// Mirror: which way to reflect. Vibrate: which way to shake.
    public var axis: MotionAxis = .horizontal
    /// Shift: which way motion falls.
    public var direction: MotionDirection = .down
    /// Zoom, Slam Zoom, Shear: where the pull radiates from, as fractions of
    /// the frame (0.5, 0.5 is the middle).
    public var centreX: Double = 0.5
    public var centreY: Double = 0.5
    /// Delay: how much of the motion further back trails into the echo.
    public var feedback: Double = 0
    /// Noise: how still a block must be, as a fraction of the fastest
    /// block's speed, before it is thrown around.
    public var threshold: Double = 0.7

    public init(id: UUID = UUID(), enabled: Bool = true, kind: VectorOpKind,
                source: TriggerSource, note: Int? = nil, band: OnsetBand? = nil,
                duration: Double = 0.3, durationJitter: Double = 0,
                amountFloor: Double? = nil, strengthInfluence: Double = 0.5,
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
        self.amountFloor = amountFloor ?? kind.defaultAmount
        self.strengthInfluence = strengthInfluence
        self.probability = probability
        self.offset = offset
        self.activeRegions = activeRegions
        // Vibrate shakes on both axes by default; Mirror reflects left-right.
        self.axis = kind == .vibrate ? .both : .horizontal
    }

    /// The settings the effect's script function reads after Amount, in its
    /// own order.
    public var params: [Double] {
        switch kind {
        case .mirror, .vibrate: return [Double(axis.index)]
        case .shift: return [Double(direction.index)]
        case .zoom, .slamZoom, .shear: return [centreX, centreY]
        case .delay: return [feedback]
        case .noise: return [threshold]
        default: return []
        }
    }

    public func isActive(at time: Double) -> Bool {
        activeRegions.isEmpty || activeRegions.contains { $0.contains(time) }
    }

    public func matches(_ event: TriggerEvent) -> Bool {
        guard enabled else { return false }
        if let target = event.ruleID { return target == id }
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
        // One generator per rule — see TriggerCompiler.
        var rngs: [UUID: SplitMix64] = [:]
        var ops: [VectorOp] = []

        for event in events.sorted(by: { $0.time < $1.time }) {
            for (chain, rule) in rules.enumerated() where rule.matches(event) {
                var rng = rngs[rule.id] ?? SplitMix64(seed: seed ^ (UInt64(rule.seed) &* 0x9E37_79B9_7F4A_7C15))
                defer { rngs[rule.id] = rng }
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
                let end = start + max(1, Int((duration * frameRate).rounded()))
                let lo = max(0, start)
                let hi = min(frameCount, end)
                guard lo < hi else { continue }

                // Bipolar effects (Zoom, Slam Zoom, Shear) are neutral at 0.5,
                // so a weaker hit scales the distance from the middle rather
                // than the value itself — otherwise a soft hit on an outward
                // zoom would flip it into an inward one.
                let scale = velocityScale(strength: event.strength,
                                          velocity: rule.strengthInfluence)
                let amount = rule.kind.isBipolar
                    ? 0.5 + (rule.amountFloor - 0.5) * scale
                    : rule.amountFloor * scale

                var op = VectorOp(kind: rule.kind, startFrame: lo, length: hi - lo,
                                  amount: amount, seed: rng.next())
                op.chain = chain
                op.params = rule.params
                op.decay = rule.decay
                ops.append(op)
            }
        }

        return ops
    }
}
