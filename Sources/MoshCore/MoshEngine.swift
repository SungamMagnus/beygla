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
    /// Genuine still frame: emit skip frames so the decoder repeats the
    /// last picture with no motion applied at all.
    case freeze
    /// Kill every frame carrying more data than a threshold. Keyframes go, and
    /// so do the heavy refresh frames a codec spends on a sudden change.
    case void
    /// Swap adjacent frames throughout the range.
    case invert
    /// Interleave the range forwards and backwards at once.
    case weave
    /// Displace each frame in time by a random amount, gaussian about zero.
    case jiggle
    /// Overlapping runs: take a chunk, step back less than its length, repeat.
    case overlap
    /// Reorder the range by how much data each frame carries.
    case sort
    /// Skip forward through the range, then hold what is left.
    case rise
    /// Shuffle blocks of frames rather than single frames, so local motion
    /// survives inside each block.
    case blockShuffle

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
        case .void: return "Void"
        case .invert: return "Invert"
        case .weave: return "Weave"
        case .jiggle: return "Jiggle"
        case .overlap: return "Overlap"
        case .sort: return "Sort"
        case .rise: return "Rise"
        case .blockShuffle: return "Blocks"
        }
    }

    /// What the effect does to the bitstream, and what that looks like — one
    /// or two sentences, short enough to sit under the controls.
    ///
    /// A compressed stream has two kinds of frame: a keyframe, which is a whole
    /// picture, and a delta frame, which carries only motion vectors and a small
    /// correction — instructions for moving the previous picture's pixels around.
    /// Every effect here works by lying about which pixels those instructions
    /// were meant for.
    public var blurb: String {
        switch self {
        case .bloom:
            return "Deletes the keyframes in range, so the next scene's motion drags the old scene's pixels around. Strongest on a hard cut."
        case .glide:
            return "Repeats one delta frame through the range, so the picture keeps sliding one way and smears. Longer ranges drift further."
        case .echo:
            return "Loops the first few delta frames, so the image churns in a cycle. Amount sets the loop length."
        case .stutter:
            return "Keeps one frame in every few and holds between them: a hard, rhythmic judder. Amount sets the step."
        case .reverse:
            return "Plays the range's motion backwards over a picture that never resets, so shapes crawl back through themselves."
        case .shuffle:
            return "Scrambles the delta frames, so blocks tear and drift apart. Seeded, so a project always renders the same."
        case .freeze:
            return "Holds the picture dead still with no smear. Good as a rest between two moving effects."
        case .void:
            return "Drops every frame heavier than a threshold, keyframes first, so the picture drifts instead of cutting. Amount sets the threshold."
        case .invert:
            return "Swaps each frame with its neighbour, so motion steps forward and back: a fine shudder that keeps its subject."
        case .weave:
            return "Alternates the range forwards and backwards, pulling the picture apart and back together every frame."
        case .jiggle:
            return "Nudges each frame a random distance in time, so motion stumbles. Amount sets how far."
        case .overlap:
            return "Each run of frames replays part of the one before, stacking half-finished movements. Amount sets the run length."
        case .sort:
            return "Reorders frames by size, which tracks how much changed. Below half builds quiet to loud; above half starts loud and decays."
        case .rise:
            return "Skips ahead through the range, then holds the last frame it reached. Amount sets the stride."
        case .blockShuffle:
            return "Shuffles in blocks, so motion stays smooth inside each one and jumps at the joins, like a stutter edit. Amount sets the block length."
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
        case .void: return "Every heavy frame killed"
        case .invert: return "Neighbouring frames swapped"
        case .weave: return "Forwards and backwards at once"
        case .jiggle: return "Each frame knocked off its mark"
        case .overlap: return "Runs that double back on themselves"
        case .sort: return "Reordered by how much data each frame holds"
        case .rise: return "Skips ahead, then holds"
        case .blockShuffle: return "Blocks scrambled, motion intact inside"
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
    /// Position of the rule that made this op in its effect chain. Ops are
    /// applied chain position first, so the order of the effect list is the
    /// order the effects process the frames in — later ones work on what
    /// earlier ones produced, like a rack.
    public var chain: Int = 0

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

        // Chain order first, then time. Sorting by time alone — as this did —
        // made the order of the effect list meaningless.
        for op in ops.sorted(by: { ($0.chain, $0.startFrame) < ($1.chain, $1.startFrame) }) {
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

        case .void:
            // Frame size tracks how much of the picture changed. Keyframes are
            // the largest frames in any stream, so a size threshold takes them
            // first and then eats into the heavy refresh frames behind them.
            let biggest = frames[lo ..< hi].map(\.payload.count).max() ?? 0
            guard biggest > 0 else { return }
            let threshold = Double(biggest) * (1.0 - 0.92 * op.amount)
            for i in lo ..< hi where Double(frames[i].payload.count) > threshold {
                frames[i] = hold
            }

        case .invert:
            var i = lo
            while i + 1 < hi {
                frames.swapAt(i, i + 1)
                i += 2
            }
            for i in lo ..< hi where frames[i].isKey { frames[i] = hold }

        case .weave:
            // First, last, second, second-last, inwards.
            let slice = Array(frames[lo ..< hi])
            var woven: [AVIFrame] = []
            woven.reserveCapacity(slice.count)
            var head = 0, tail = slice.count - 1
            while woven.count < slice.count {
                woven.append(slice[head]); head += 1
                if woven.count < slice.count { woven.append(slice[tail]); tail -= 1 }
            }
            for i in woven.indices where woven[i].isKey { woven[i] = hold }
            frames.replaceSubrange(lo ..< hi, with: woven)

        case .jiggle:
            var rng = SplitMix64(seed: op.seed &+ UInt64(lo))
            let sigma = 1.0 + op.amount * 12.0
            let slice = Array(frames[lo ..< hi])
            var out: [AVIFrame] = []
            out.reserveCapacity(slice.count)
            for i in slice.indices {
                let target = i + Int(gaussian(&rng, sigma: sigma).rounded())
                out.append(slice[min(max(target, 0), slice.count - 1)])
            }
            for i in out.indices where out[i].isKey { out[i] = hold }
            frames.replaceSubrange(lo ..< hi, with: out)

        case .overlap:
            let run = max(2, Int((2.0 + op.amount * 14.0).rounded()))
            let step = max(1, run / 2)          // step back less than the run
            let slice = Array(frames[lo ..< hi])
            var out: [AVIFrame] = []
            out.reserveCapacity(slice.count)
            var start = 0
            while out.count < slice.count {
                for k in 0 ..< run where out.count < slice.count {
                    out.append(slice[min(start + k, slice.count - 1)])
                }
                start += step
                if start >= slice.count { start = 0 }
            }
            for i in out.indices where out[i].isKey { out[i] = hold }
            frames.replaceSubrange(lo ..< hi, with: out)

        case .sort:
            var slice = Array(frames[lo ..< hi])
            let descending = op.amount >= 0.5
            slice.sort { descending
                ? $0.payload.count > $1.payload.count
                : $0.payload.count < $1.payload.count }
            for i in slice.indices where slice[i].isKey { slice[i] = hold }
            frames.replaceSubrange(lo ..< hi, with: slice)

        case .rise:
            let stride = max(2, Int((1.0 + op.amount * 8.0).rounded()))
            let slice = Array(frames[lo ..< hi])
            var out: [AVIFrame] = []
            out.reserveCapacity(slice.count)
            var i = 0
            while out.count < slice.count {
                if i < slice.count {
                    out.append(slice[i])
                    i += stride
                } else {
                    out.append(hold)          // arrived early, so wait
                }
            }
            for i in out.indices where out[i].isKey { out[i] = hold }
            frames.replaceSubrange(lo ..< hi, with: out)

        case .blockShuffle:
            var rng = SplitMix64(seed: op.seed &+ UInt64(lo))
            let block = max(2, Int((2.0 + op.amount * 14.0).rounded()))
            let slice = Array(frames[lo ..< hi])
            var blocks: [[AVIFrame]] = []
            var i = 0
            while i < slice.count {
                blocks.append(Array(slice[i ..< min(i + block, slice.count)]))
                i += block
            }
            guard blocks.count > 1 else { return }
            // Fisher-Yates over the blocks, so motion inside one stays intact
            // and only the joins are wrong.
            for n in stride(from: blocks.count - 1, to: 0, by: -1) {
                blocks.swapAt(n, Int(rng.next() % UInt64(n + 1)))
            }
            var out = Array(blocks.joined())
            while out.count < slice.count { out.append(hold) }
            out = Array(out.prefix(slice.count))
            for i in out.indices where out[i].isKey { out[i] = hold }
            frames.replaceSubrange(lo ..< hi, with: out)
        }
    }

    /// Box-Muller, for jiggle's displacement.
    private static func gaussian(_ rng: inout SplitMix64, sigma: Double) -> Double {
        let u1 = Double(rng.next() % 1_000_000 + 1) / 1_000_001.0
        let u2 = Double(rng.next() % 1_000_000) / 1_000_000.0
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2) * sigma
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
