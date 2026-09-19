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
            return "Deletes the keyframes inside the range. With no whole picture to reset to, the incoming scene's motion vectors are applied to the outgoing scene's pixels: the old image gets dragged around by the new image's movement, holding its colours while taking on the wrong shape. It bites hardest at a hard cut, where the two pictures have nothing in common."
        case .glide:
            return "Picks the last delta frame before the range and re-applies that same one for every frame in it. The decoder keeps shifting pixels in the one direction that frame described, so the picture slides steadily and smears into itself. It does not decay — a longer range drifts further, and the image eventually pulls apart."
        case .echo:
            return "Loops the first few delta frames of the range over and over. The same short burst of motion replays on an ever-changing picture, so the image churns in a cycle instead of drifting one way. Amount sets the loop length: low is a tight flutter, high is a longer repeating phrase."
        case .stutter:
            return "Keeps one frame in every few and replaces the rest with skip frames, so the picture updates in steps rather than continuously. The result is a hard rhythmic judder that holds dead still between updates. Amount sets the step: higher holds longer and reads slower and coarser."
        case .reverse:
            return "Plays the range's delta frames back to front. Motion that was pushing one way now pulls the other, against a picture that never reset, so shapes crawl backwards through themselves. Any keyframe landing inside the reversed run is neutralised — left in, it would snap the picture back."
        case .shuffle:
            return "Randomly permutes the delta frames in the range, so each frame's motion is applied at the wrong moment to the wrong picture. The image tears into blocks that drift independently. The render is seeded, so the same project always produces the same scramble."
        case .freeze:
            return "Replaces every frame in the range with a skip frame, which tells the decoder the picture is unchanged. Motion stops dead and nothing smears — the one effect here that holds perfectly still. Useful as a held beat between two moving ones."
        case .void:
            return "Kills every frame carrying more data than a threshold. Keyframes are the biggest frames in any stream so they go first, but so do the heavy refresh frames a codec spends whenever too much of the picture changes at once. What survives is only the cheap, small motion, which is why the result drifts rather than cuts. Amount sets how aggressive the threshold is."
        case .invert:
            return "Swaps each frame with its neighbour, so every pair of instructions arrives in the wrong order. Motion advances then immediately corrects itself, one frame out of step the whole way through, and the picture develops a fine shudder without ever losing its subject."
        case .weave:
            return "Interleaves the range with itself reversed: first frame, last frame, second, second-last, and inwards. Two contradictory directions of motion are applied on alternate frames, so the picture is pulled apart and back together at the frame rate. Keyframes inside the range are neutralised."
        case .jiggle:
            return "Displaces each frame in time by a random amount drawn from a bell curve about zero, so the stream mostly advances but never lands exactly where it should. Motion stumbles rather than tears. Amount widens the curve — small values read as nervousness, large ones scramble the range."
        case .overlap:
            return "Takes a run of frames, steps back less than the run's length, and takes another — so every run replays part of the one before it. Motion keeps starting over before it has finished, which stacks partial movements on top of each other. Amount sets the run length."
        case .sort:
            return "Reorders the range by how many bytes each frame carries. Frame size tracks how much changed, so this sorts by how violent each moment was and plays them in that order. Below halfway it runs quiet to loud and gathers into a burst; above, it leads with the violence and decays."
        case .rise:
            return "Skips forward through the range, taking every second frame or every eighth, then holds on the last one it reached. Motion accelerates away and then stops dead. Amount sets the stride, so a long range with a wide stride arrives early and waits."
        case .blockShuffle:
            return "Shuffles the range in blocks rather than one frame at a time, so motion stays coherent inside each block and only the joins between them are wrong. The picture keeps moving convincingly and then jumps, which reads as a stutter edit rather than as noise. Amount sets the block length."
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
