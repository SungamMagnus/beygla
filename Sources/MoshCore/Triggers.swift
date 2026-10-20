import Foundation

public enum TriggerSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case audio, midi, sync, manual

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .audio: return "Audio in"
        case .midi: return "MIDI in"
        case .sync: return "Sync"
        case .manual: return "Manual"
        }
    }
}

/// One moment where something should happen. Everything upstream — offline
/// onset analysis, a live mic, a MIDI controller, a click on the timeline —
/// converges on this type, so the renderer never needs to care where a hit
/// came from.
public struct TriggerEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Seconds from the start of the clip.
    public var time: Double
    /// 0...1. Onset strength, or MIDI velocity / 127.
    public var strength: Double
    public var source: TriggerSource
    /// MIDI note number, when the event came from a controller.
    public var note: Int?
    /// Which band detected it, when the event came from audio.
    public var band: OnsetBand?
    /// The one effect this trigger fires, when it was placed on that effect's
    /// own lane. Nil means it is a shared trigger, routed by source as usual.
    public var ruleID: UUID?
    /// How long this one trigger's effect lasts, when its bar was dragged to
    /// a length of its own. Only for a lane's own triggers; a shared
    /// trigger's length per effect lives on the rule (`spanOverrides`).
    public var duration: Double?

    public init(id: UUID = UUID(), time: Double, strength: Double = 1.0,
                source: TriggerSource, note: Int? = nil, band: OnsetBand? = nil,
                ruleID: UUID? = nil) {
        self.id = id
        self.time = time
        self.strength = strength
        self.source = source
        self.note = note
        self.band = band
        self.ruleID = ruleID
    }
}

/// A note length on the sync grid, in beats of 4/4.
public enum NoteValue: String, Codable, CaseIterable, Identifiable, Sendable {
    case bar, half, quarter, eighth, sixteenth, quarterTriplet, eighthTriplet

    public var id: String { rawValue }

    /// Length in quarter-note beats.
    public var beats: Double {
        switch self {
        case .bar: return 4
        case .half: return 2
        case .quarter: return 1
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        case .quarterTriplet: return 2.0 / 3.0
        case .eighthTriplet: return 1.0 / 3.0
        }
    }

    public var displayName: String {
        switch self {
        case .bar: return "1 bar"
        case .half: return "1/2"
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        case .quarterTriplet: return "1/4T"
        case .eighthTriplet: return "1/8T"
        }
    }
}

/// A trigger's identity for per-effect settings that must survive the
/// trigger list being rebuilt. Analysed onsets and the sync grid are
/// regenerated with fresh IDs whenever detection settings change, so a
/// length or exclusion keyed by ID would vanish on the next slider nudge;
/// keyed by time, to the millisecond, it stays with the hit.
public func triggerKey(_ time: Double) -> Int { Int((time * 1000).rounded()) }

/// A fixed tempo grid that triggers effects in time with a track.
public struct SyncSettings: Codable, Hashable, Sendable {
    public var bpm: Double
    public var noteValue: NoteValue
    /// Where beat 1 of bar 1 falls, in seconds. Hits before it are still
    /// generated, counting backward, so a track with a pickup is covered.
    public var offset: Double
    /// Give the first beat of each bar full strength and the rest less, so a
    /// rule's Velocity knob can make the downbeat hit hardest.
    public var accentDownbeat: Bool

    public init(bpm: Double = 120, noteValue: NoteValue = .quarter,
                offset: Double = 0, accentDownbeat: Bool = true) {
        self.bpm = bpm
        self.noteValue = noteValue
        self.offset = offset
        self.accentDownbeat = accentDownbeat
    }

    /// Seconds between two hits on the grid.
    public var interval: Double { 60.0 / max(1, bpm) * noteValue.beats }

    public static let bpmRange: ClosedRange<Double> = 40 ... 300
}

public enum SyncGrid {
    /// Every grid hit from 0 to `duration`.
    ///
    /// Positions are computed as `offset + n * interval` from an integer n
    /// rather than by repeatedly adding the interval, so a long clip does not
    /// accumulate floating-point drift and land its last hits late.
    public static func events(settings: SyncSettings, duration: Double) -> [TriggerEvent] {
        let interval = settings.interval
        guard interval > 0.005, duration > 0 else { return [] }

        let first = Int((-settings.offset / interval).rounded(.up))
        let last = Int(((duration - settings.offset) / interval).rounded(.down))
        guard first <= last else { return [] }

        var out: [TriggerEvent] = []
        out.reserveCapacity(last - first + 1)
        for n in first ... last {
            let t = settings.offset + Double(n) * interval
            guard t >= 0, t < duration else { continue }

            var strength = 1.0
            if settings.accentDownbeat {
                // Beats from beat 1, folded into a 4/4 bar.
                let beatsIn = Double(n) * settings.noteValue.beats
                let inBar = beatsIn.truncatingRemainder(dividingBy: 4)
                let wrapped = inBar < 0 ? inBar + 4 : inBar
                strength = wrapped < 0.001 || wrapped > 3.999 ? 1.0 : 0.55
            }
            out.append(TriggerEvent(time: t, strength: strength, source: .sync))
        }
        return out
    }
}

/// A span of the timeline where one effect is live.
///
/// A rule with no regions is active everywhere. Paint one or more and the rule
/// only fires on triggers that land inside them — which is how a set of effects
/// takes turns over a clip instead of all of them firing on every hit.
public struct ActiveRegion: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public func contains(_ t: Double) -> Bool { t >= start && t <= end }
}

/// Turns trigger events into mosh ops. A rule is the bridge between "the kick
/// hit" and "smear 8 frames of video".
public struct MoshRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var kind: MoshOpKind
    public var source: TriggerSource

    /// nil matches any note; set it to bind one pad or key to this effect.
    public var note: Int?
    /// nil matches any band.
    public var band: OnsetBand?

    /// How long the effect runs, in seconds.
    public var duration: Double
    /// Fraction of `duration` added or removed at random, 0...1.
    public var durationJitter: Double
    /// Effect amount when the trigger is at zero strength.
    public var amountFloor: Double
    /// How much trigger strength pushes the amount up towards 1.
    public var strengthInfluence: Double
    /// 0...1 chance of firing at all — lets a rule thin itself out.
    public var probability: Double
    /// Nudge the effect earlier or later, in seconds. Useful to compensate for
    /// the fact that a smear reads a frame or two after the hit.
    public var offset: Double
    /// Spans of the timeline where this effect is live. Empty means everywhere.
    public var activeRegions: [ActiveRegion]
    /// This effect's own random seed: what Shuffle, Jiggle and Blocks
    /// scramble with, and what Chance and Jitter roll with. Same seed, same
    /// render; a new seed is a new variation with nothing else changed.
    public var seed: UInt32
    /// Force a clean keyframe the moment each of this effect's spans ends,
    /// so the picture resets there instead of smearing on.
    public var resetAfter: Bool = false
    /// Spans dragged to a length of their own on the timeline, by shared
    /// trigger (`triggerKey`), in seconds.
    public var spanOverrides: [Int: Double] = [:]
    /// Shared triggers this effect ignores, by `triggerKey` — removed from
    /// this effect's lane without deleting them for every other effect.
    public var excludedTriggers: Set<Int> = []

    /// How long this effect runs for one trigger.
    public func duration(for event: TriggerEvent) -> Double {
        if event.ruleID == id { return event.duration ?? duration }
        return spanOverrides[triggerKey(event.time)] ?? duration
    }

    /// Whether this trigger's span was given a length of its own.
    public func hasOwnLength(_ event: TriggerEvent) -> Bool {
        event.ruleID == id ? event.duration != nil : spanOverrides[triggerKey(event.time)] != nil
    }

    public init(id: UUID = UUID(), enabled: Bool = true, kind: MoshOpKind,
                source: TriggerSource, note: Int? = nil, band: OnsetBand? = nil,
                duration: Double = 0.25, durationJitter: Double = 0,
                amountFloor: Double? = nil, strengthInfluence: Double = 0.6,
                probability: Double = 1.0, offset: Double = 0,
                activeRegions: [ActiveRegion] = [], seed: UInt32 = 1) {
        self.id = id
        self.enabled = enabled
        self.kind = kind
        self.source = source
        self.note = note
        self.band = band
        self.duration = duration
        self.durationJitter = durationJitter
        self.amountFloor = amountFloor ?? kind.defaultAmount
        self.seed = seed
        self.strengthInfluence = strengthInfluence
        self.probability = probability
        self.offset = offset
        self.activeRegions = activeRegions
    }

    /// Whether the effect is live at this point on the timeline.
    public func isActive(at time: Double) -> Bool {
        activeRegions.isEmpty || activeRegions.contains { $0.contains(time) }
    }

    public func matches(_ event: TriggerEvent) -> Bool {
        guard enabled else { return false }
        // A trigger placed on one effect's own lane is for that effect alone,
        // and is not gated by its painted spans: it was put exactly there.
        if let target = event.ruleID { return target == id }
        if excludedTriggers.contains(triggerKey(event.time)) { return false }
        // Painted regions gate every source, a hand-placed trigger included: if
        // you drew where an effect is live, a trigger outside it should not
        // wake it up.
        guard isActive(at: event.time) else { return false }
        // A hand-placed trigger is an explicit instruction — do this, here — so
        // it fires every enabled effect regardless of what that effect is
        // otherwise listening to. Filtering it by source would mean a trigger
        // you placed yourself drew a tick on the timeline and then did nothing,
        // which is not a filter anyone asked for.
        if event.source == .manual { return true }
        guard source == event.source else { return false }
        if let n = note, event.note != n { return false }
        if let b = band, let eb = event.band, b != eb { return false }
        return true
    }

    public static func defaultSet() -> [MoshRule] {
        [
            MoshRule(kind: .bloom, source: .audio, band: .low,
                     duration: 0.4, amountFloor: 0.6, strengthInfluence: 0.4),
            MoshRule(enabled: false, kind: .glide, source: .audio, band: .mid,
                     duration: 0.2, amountFloor: 0.5, strengthInfluence: 0.5),
            MoshRule(enabled: false, kind: .stutter, source: .audio, band: .high,
                     duration: 0.15, amountFloor: 0.3, strengthInfluence: 0.7),
        ]
    }
}

/// How much of an effect's Amount a trigger delivers. A full-strength hit
/// gets all of it; Velocity sets how far a weaker hit falls short, so at 0 every
/// hit is the same and at 1 a hit's strength scales the Amount directly.
///
/// This used to be `Amount + strength × Velocity`, clamped to 1. With the
/// default Velocity of 0.6 any full-strength trigger — every hand-placed one,
/// every accented beat, every strong onset — already reached 1 at Amount 0.4,
/// so the whole top of the Amount range changed nothing at all.
public func velocityScale(strength: Double, velocity: Double) -> Double {
    let s = min(max(strength, 0), 1), v = min(max(velocity, 0), 1)
    return 1 - v * (1 - s)
}

public enum TriggerCompiler {
    /// Compile events + rules into the op list the engine consumes.
    ///
    /// Seeded from the project seed so a render is reproducible: the same
    /// project always produces the same shuffle and the same jitter.
    public static func compile(events: [TriggerEvent], rules: [MoshRule],
                               frameRate: Double, frameCount: Int,
                               seed: UInt64 = 0x4D05_4842) -> [MoshOp] {
        // One generator per rule, seeded from that rule's own seed, so
        // changing one effect's seed rerolls only that effect.
        var rngs: [UUID: SplitMix64] = [:]
        var ops: [MoshOp] = []

        for event in events.sorted(by: { $0.time < $1.time }) {
            for (chain, rule) in rules.enumerated() where rule.matches(event) {
                var rng = rngs[rule.id] ?? SplitMix64(seed: seed ^ (UInt64(rule.seed) &* 0x9E37_79B9_7F4A_7C15))
                defer { rngs[rule.id] = rng }
                if rule.probability < 1.0 {
                    let roll = Double(rng.next() % 10_000) / 10_000.0
                    if roll > rule.probability { continue }
                }

                // A span dragged to its own length keeps exactly that length.
                var duration = rule.duration(for: event)
                if rule.durationJitter > 0 && !rule.hasOwnLength(event) {
                    let j = (Double(rng.next() % 2_000) / 1_000.0 - 1.0) * rule.durationJitter
                    duration *= max(0.1, 1.0 + j)
                }

                let start = Int(((event.time + rule.offset) * frameRate).rounded())
                let end = start + max(1, Int((duration * frameRate).rounded()))
                // Keep only the part of the span that lands inside the clip
                // being rendered. With an in point set, triggers before it
                // arrive here with negative times; clamping only the start
                // to 0 would pile every one of them onto the first frame.
                let lo = max(0, start)
                let hi = min(frameCount, end)
                guard lo < hi else { continue }

                let amount = rule.amountFloor
                    * velocityScale(strength: event.strength, velocity: rule.strengthInfluence)

                var op = MoshOp(kind: rule.kind, startFrame: lo, length: hi - lo,
                                amount: amount, seed: rng.next())
                op.chain = chain
                op.resetAfter = rule.resetAfter
                ops.append(op)
            }
        }

        return ops
    }
}
