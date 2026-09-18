import Foundation

/// Deterministic RNG so a given seed always renders the same mosh.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum MoshOpKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Delete the keyframes in range so the incoming motion vectors land on
    /// whatever pixels were already on screen. The classic transition smear.
    case bloom
    /// Hold one delta frame and re-apply it for the whole range: the picture
    /// keeps sliding in a fixed direction.
    case glide
    /// Cycle a short window of delta frames, giving a rhythmic pulsing churn.
    case echo
    /// Hold each frame for several slots, dropping the ones in between.
    case stutter
    /// Play the range's motion backwards. Pixels crawl the wrong way.
    case reverse
    /// Randomly permute the delta frames in range.
    case shuffle
    /// Genuine still frame: emit zero-length chunks so the decoder repeats the
    /// last picture with no motion applied at all.
    case freeze

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bloom: return "Bloom"
        case .glide: return "Glide"
        case .echo: return "Echo"
        case .stutter: return "Stutter"
        case .reverse: return "Reverse"
        case .shuffle: return "Shuffle"
        case .freeze: return "Freeze"
        }
    }

    /// What the effect does to the bitstream, and what that looks like.
    ///
    /// A compressed stream has two kinds of frame: a keyframe, which is a whole
    /// picture, and a delta frame, which carries only motion vectors and a small
    /// correction — instructions for moving the previous picture's pixels around.
    /// Every effect here works by lying about which pixels those instructions
    /// were meant for.
    public var blurb: String {
        switch self {
        case .bloom:
            return """
            Deletes the keyframes inside the range. With no whole picture to             reset to, the incoming scene's motion vectors are applied to the             outgoing scene's pixels: the old image gets dragged around by the             new image's movement, holding its colours while taking on the             wrong shape. This is the classic smear, and it bites hardest at a             hard cut, where the two pictures have nothing in common.
            """
        case .glide:
            return """
            Picks the last delta frame before the range and re-applies that             same one for every frame in it. The decoder keeps shifting pixels             in the one direction that frame described, so the picture slides             steadily and smears into itself. It does not decay — a longer             range drifts further, and the image eventually pulls apart.
            """
        case .echo:
            return """
            Loops the first few delta frames of the range over and over. The             same short burst of motion replays on an ever-changing picture, so             the image churns in a cycle instead of drifting one way. Amount             sets how many frames are in the loop: low is a tight flutter, high             is a longer repeating phrase.
            """
        case .stutter:
            return """
            Keeps one frame in every few and replaces the rest with skip             frames, so the picture updates in steps rather than continuously.             The result is a hard rhythmic judder that holds dead still between             updates. Amount sets the step: higher holds longer and reads             slower and coarser.
            """
        case .reverse:
            return """
            Plays the range's delta frames back to front. Motion that was             pushing one way now pulls the other, against a picture that never             reset, so shapes crawl backwards through themselves. Any keyframe             that lands inside the reversed run is neutralised — left in, it             would snap the picture back and undo the effect.
            """
        case .shuffle:
            return """
            Randomly permutes the delta frames in the range, so each frame's             motion is applied at the wrong moment to the wrong picture. The             image tears into blocks that drift independently. Amount sets how             many swaps are made; the render is seeded, so the same project             always produces the same scramble.
            """
        case .freeze:
            return """
            Replaces every frame in the range with a skip frame, which tells             the decoder the picture is unchanged. Motion stops dead and             nothing smears — the one effect here that holds perfectly still.             Useful as a held beat between two moving ones.
            """
        }
    }

    /// The one-line version, for the collapsed row.
    public var summary: String {
        switch self {
        case .bloom: return "New motion smeared over old pixels"
        case .glide: return "One frame of motion, held and repeated"
        case .echo: return "A short loop of motion, cycling"
        case .stutter: return "Steps forward, holds still between"
        case .reverse: return "The range's motion, backwards"
        case .shuffle: return "Motion applied to the wrong frames"
        case .freeze: return "Dead still, no motion at all"
        }
    }
}

public struct MoshOp: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MoshOpKind
    /// First video frame index the op covers.
    public var startFrame: Int
    /// Number of frames covered. Ops never change the total frame count, so
    /// this is exactly how many slots get rewritten.
    public var length: Int
    /// 0...1 — usually trigger velocity or onset strength.
    public var amount: Double
    public var seed: UInt64

    public init(id: UUID = UUID(), kind: MoshOpKind, startFrame: Int, length: Int,
                amount: Double = 0.7, seed: UInt64 = 0x5EED) {
        self.id = id
        self.kind = kind
        self.startFrame = startFrame
        self.length = length
        self.amount = amount
        self.seed = seed
    }

    public var endFrame: Int { startFrame + length }
}

public struct MoshSettings: Codable, Sendable {
    /// Remove every keyframe past the first one, for the "never resets" look.
    public var purgeAllKeyframes: Bool = false
    /// Keep the very first frame intact so the clip has something to start from.
    public var protectFirstFrame: Bool = true

    public init(purgeAllKeyframes: Bool = false, protectFirstFrame: Bool = true) {
        self.purgeAllKeyframes = purgeAllKeyframes
        self.protectFirstFrame = protectFirstFrame
    }
}

public enum MoshEngine {
    /// Apply the op list to a document in place.
    ///
    /// Ops are applied in start order and each one only ever rewrites the slots
    /// it covers, so the frame count never changes. That invariant is what keeps
    /// the render locked to the audio: every trigger still lands on the frame it
    /// was fired on, no matter how violent the mosh gets.
    public static func apply(ops: [MoshOp], settings: MoshSettings = .init(), to doc: AVIDocument) {
        var frames = doc.frames
        guard !frames.isEmpty else { return }
        let holdFrame = doc.skipFrame

        if settings.purgeAllKeyframes {
            for i in frames.indices where frames[i].isKey {
                if settings.protectFirstFrame && i == 0 { continue }
                frames[i] = holdFrame
            }
        }

        for op in ops.sorted(by: { $0.startFrame < $1.startFrame }) {
            let lo = max(settings.protectFirstFrame ? 1 : 0, op.startFrame)
            let hi = min(frames.count, op.endFrame)
            guard lo < hi else { continue }
            applyOne(op, lo: lo, hi: hi, hold: holdFrame, frames: &frames)
        }

        doc.frames = frames
    }

    private static func applyOne(_ op: MoshOp, lo: Int, hi: Int, hold: AVIFrame, frames: inout [AVIFrame]) {
        switch op.kind {
        case .bloom:
            for i in lo ..< hi where frames[i].isKey {
                frames[i] = hold
            }

        case .glide:
            // Source is the last delta frame before the range — that is the
            // motion we want to keep re-applying.
            guard let src = lastDelta(before: lo, in: frames) else { return }
            let payload = MPEG4.strippingHeaders(frames[src].payload)
            for i in lo ..< hi { frames[i] = AVIFrame(payload: payload) }

        case .echo:
            let window = max(1, Int((1.0 + op.amount * 15.0).rounded()))
            var source: [AVIFrame] = []
            var i = lo
            while i < hi && source.count < window {
                if frames[i].isDelta { source.append(frames[i]) }
                i += 1
            }
            guard !source.isEmpty else { return }
            for (n, idx) in (lo ..< hi).enumerated() {
                frames[idx] = source[n % source.count]
            }

        case .stutter:
            let step = max(2, Int((2.0 + op.amount * 14.0).rounded()))
            for (n, idx) in (lo ..< hi).enumerated() where n % step != 0 {
                frames[idx] = hold
            }

        case .reverse:
            var slice = Array(frames[lo ..< hi])
            slice.reverse()
            // A keyframe dragged into the middle would snap the picture back, so
            // neutralise any that ended up inside the reversed run.
            for i in slice.indices where slice[i].isKey { slice[i] = hold }
            frames.replaceSubrange(lo ..< hi, with: slice)

        case .shuffle:
            var rng = SplitMix64(seed: op.seed &+ UInt64(lo))
            var slice = Array(frames[lo ..< hi])
            let swaps = max(1, Int(Double(slice.count) * max(0.05, op.amount)))
            for _ in 0 ..< swaps {
                let a = Int(rng.next() % UInt64(slice.count))
                let b = Int(rng.next() % UInt64(slice.count))
                slice.swapAt(a, b)
            }
            for i in slice.indices where slice[i].isKey { slice[i] = hold }
            frames.replaceSubrange(lo ..< hi, with: slice)

        case .freeze:
            for i in lo ..< hi { frames[i] = hold }
        }
    }

    private static func lastDelta(before index: Int, in frames: [AVIFrame]) -> Int? {
        var i = min(index, frames.count) - 1
        while i >= 0 {
            if frames[i].isDelta && !frames[i].payload.isEmpty { return i }
            i -= 1
        }
        return nil
    }
}
