import Foundation

public struct RenderRequest: Sendable {
    public var input: URL
    public var output: URL
    /// An audio file to use in place of the video's own track. It drives the
    /// onset analysis upstream, and it is the track muxed into the render, so
    /// what you cut to is what you hear.
    public var audioSource: URL?
    public var events: [TriggerEvent]
    public var rules: [MoshRule]
    /// The second effect family — rewrites motion vectors inside frames
    /// rather than reordering whole ones. Runs before the bitstream pass, on
    /// the same source, so combining both costs no extra generation of lossy
    /// re-encoding: the vector pass's own encode is the same one the
    /// bitstream pass would otherwise have needed anyway.
    public var vectorRules: [VectorRule]
    public var settings: MoshSettings
    /// Force keyframes at trigger times so `bloom` has something to strip.
    /// Without this a clip encoded with a single keyframe has nothing to bloom.
    public var seedKeyframesAtTriggers: Bool
    public var quality: Int
    public var previewWidth: Int?
    public var trim: ClosedRange<Double>?
    public var seed: UInt64
    /// How much of the moshed picture shows over the clean source in the
    /// output, 0...1. The one control that scales every effect in both
    /// families the same way, because it acts on finished pictures rather
    /// than on any one effect's parameters.
    public var mix: Double = 1
    /// How long the damage an effect leaves behind lingers after the effect
    /// ends, in seconds, before a clean keyframe resets the picture. nil
    /// means never: the smear runs until something else repaints the frame,
    /// which is how every render behaved before this existed.
    public var smear: Double? = nil

    public init(input: URL, output: URL, events: [TriggerEvent], rules: [MoshRule],
                vectorRules: [VectorRule] = [],
                audioSource: URL? = nil,
                settings: MoshSettings = .init(), seedKeyframesAtTriggers: Bool = true,
                quality: Int = 3, previewWidth: Int? = nil,
                trim: ClosedRange<Double>? = nil, seed: UInt64 = 0x4D05_4842) {
        self.input = input
        self.output = output
        self.vectorRules = vectorRules
        self.audioSource = audioSource
        self.events = events
        self.rules = rules
        self.settings = settings
        self.seedKeyframesAtTriggers = seedKeyframesAtTriggers
        self.quality = quality
        self.previewWidth = previewWidth
        self.trim = trim
        self.seed = seed
    }
}

public struct RenderReport: Sendable {
    public var frameCount: Int
    public var opCount: Int
    public var keyframesBefore: Int
    public var keyframesAfter: Int
    public var duration: Double
    public var output: URL
}

public enum RenderStage: String, Sendable {
    case probing = "Reading source"
    case encoding = "Encoding moshable stream"
    case vectorPass = "Rewriting motion vectors"
    case moshing = "Moshing frames"
    case decoding = "Rendering output"
    case done = "Done"
}

public struct RenderProgress: Sendable {
    public var stage: RenderStage
    public var fraction: Double
}

public enum RenderError: Error, LocalizedError {
    case cancelled
    public var errorDescription: String? { "Render cancelled" }
}

public final class RenderPipeline: @unchecked Sendable {
    private let tool: FFmpegTool
    /// nil when the vector-effect tool was not found. A render with no
    /// vector rules never touches it, so its absence only matters if the
    /// project actually uses one.
    private let vectorTool: FFglitchTool?
    private let token = ProcessToken()

    public init(tool: FFmpegTool, vectorTool: FFglitchTool? = nil) {
        self.tool = tool
        self.vectorTool = vectorTool
    }

    /// Kills the running ffmpeg immediately rather than waiting for the current
    /// stage to finish on its own.
    public func cancel() { token.cancel() }

    private func checkCancelled() throws {
        if token.isCancelled { throw RenderError.cancelled }
    }

    /// Seconds (relative to the start of the rendered range) at which to
    /// force a clean keyframe: `smear` after the end of every op.
    private func healTimes(_ request: RenderRequest, info: VideoInfo, smear: Double) -> [Double] {
        let base = request.trim?.lowerBound ?? 0
        let end = request.trim?.upperBound ?? info.duration
        let rate = info.frameRate
        let frames = Int(((end - base) * rate).rounded())
        guard rate > 0, frames > 0 else { return [] }

        let shifted = request.events.map { e -> TriggerEvent in
            var c = e; c.time -= base; return c
        }
        let ends = TriggerCompiler.compile(events: shifted, rules: request.rules,
                                           frameRate: rate, frameCount: frames,
                                           seed: request.seed).map(\.endFrame)
            + VectorTriggerCompiler.compile(events: shifted, rules: request.vectorRules,
                                            frameRate: rate, frameCount: frames,
                                            seed: request.seed).map(\.endFrame)
        // A hair early, so float error cannot push the forced keyframe onto
        // the frame after the one intended.
        return ends.map { Double($0) / rate + smear - 0.001 }
            .filter { $0 > 0.05 && $0 < Double(frames) / rate }
    }

    /// Encode → mosh → decode.
    public func run(_ request: RenderRequest,
                    progress: @escaping @Sendable (RenderProgress) -> Void) throws -> RenderReport {
        do {
            return try execute(request, progress: progress)
        } catch is CancellationError {
            // A killed ffmpeg throws from deep in the stack. Callers only need
            // to know the render was cancelled.
            throw RenderError.cancelled
        }
    }

    private func execute(_ request: RenderRequest,
                         progress: @escaping @Sendable (RenderProgress) -> Void) throws -> RenderReport {
        let start = Date()
        // A terminated ffmpeg throws CancellationError from deep in the stack;
        // surface all of it as one cancellation the caller can ignore quietly.
        defer { if token.isCancelled { try? FileManager.default.removeItem(at: request.output) } }
        progress(.init(stage: .probing, fraction: 0))
        let info = try tool.probe(request.input)
        try checkCancelled()

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("moshbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let rawAVI = work.appendingPathComponent("raw.avi")
        let moshedAVI = work.appendingPathComponent("moshed.avi")

        // 1. Encode to a moshable MPEG-4 AVI.
        var opts = FFmpegTool.EncodeOptions()
        opts.quality = request.quality
        opts.width = request.previewWidth
        opts.trim = request.trim
        if request.seedKeyframesAtTriggers {
            let base = request.trim?.lowerBound ?? 0
            opts.keyframeTimes = request.events
                .map { $0.time - base }
                .filter { $0 > 0.05 }
                .sorted()
        }
        // Heal points: a keyframe can only be put in the stream at encode
        // time, so the ops are compiled once here, from the probed rate,
        // purely to find where each one ends. Compilation is seeded, so these
        // are the same ops compiled again after the encode. MoshEngine never
        // strips a keyframe outside an op's own range, so each heal keyframe
        // survives and resets the picture — unless a later effect covers it,
        // in which case that effect's smear carries on, as it should.
        if let smear = request.smear {
            opts.keyframeTimes = (opts.keyframeTimes + healTimes(request, info: info, smear: smear))
                .sorted()
        }

        try tool.encodeMoshable(input: request.input, output: rawAVI, options: opts,
                                token: token) { f in
            progress(.init(stage: .encoding, fraction: f))
        }
        try checkCancelled()

        var doc = try AVIDocument(data: try Data(contentsOf: rawAVI, options: .mappedIfSafe))
        let keysBefore = doc.keyframeIndices.count

        let trimBase = request.trim?.lowerBound ?? 0
        let shifted = request.events.map { e -> TriggerEvent in
            var c = e
            c.time -= trimBase
            return c
        }

        // 2. Vector pass — rewrites motion vectors inside frames, if any rule
        // asked for one. Runs before the bitstream pass so both families can
        // be combined at the cost of exactly one extra encode generation (the
        // one `ffgac` needs to force a vector onto every macroblock), not two
        // independent renders' worth.
        let vectorOps = VectorTriggerCompiler.compile(events: shifted, rules: request.vectorRules,
                                                       frameRate: doc.frameRate,
                                                       frameCount: doc.frameCount,
                                                       seed: request.seed)
        if !vectorOps.isEmpty {
            guard let vectorTool else { throw FFglitchError.notInstalled }
            progress(.init(stage: .vectorPass, fraction: 0))

            let rawYUV = work.appendingPathComponent("vector.yuv")
            let editedStream = work.appendingPathComponent("vector.m4v")
            let vectorAVI = work.appendingPathComponent("vector.avi")

            try tool.decodeToRawYUV(input: rawAVI, output: rawYUV,
                                    width: doc.width, height: doc.height, token: token)
            try checkCancelled()

            let script = VectorEngine.generateScript(ops: vectorOps, frameCount: doc.frameCount)
            // The vector pass re-encodes, so the forced keyframes — trigger
            // points and heal points — have to be forced again in ffgac, or
            // they are lost and ffgac's own scene-change detection decides
            // where the keyframes go instead.
            try vectorTool.moshVectors(rawYUV: rawYUV, width: doc.width, height: doc.height,
                                       frameRate: doc.frameRate, script: script,
                                       quality: request.quality,
                                       keyframeTimes: opts.keyframeTimes, token: token,
                                       output: editedStream)
            try checkCancelled()

            try tool.remuxToAVI(elementaryStream: editedStream, output: vectorAVI,
                               frameRate: doc.frameRate, token: token)
            try checkCancelled()

            // Re-parse: same frame count, edited payload bytes. The bitstream
            // pass below (if any) now sees the vector-moshed picture.
            doc = try AVIDocument(data: try Data(contentsOf: vectorAVI, options: .mappedIfSafe))
            progress(.init(stage: .vectorPass, fraction: 1))
        }

        // 3. Byte surgery.
        progress(.init(stage: .moshing, fraction: 0))
        let ops = TriggerCompiler.compile(events: shifted, rules: request.rules,
                                          frameRate: doc.frameRate,
                                          frameCount: doc.frameCount,
                                          seed: request.seed)
        MoshEngine.apply(ops: ops, settings: request.settings, to: doc)
        let keysAfter = doc.keyframeIndices.count
        try doc.serialize().write(to: moshedAVI)
        progress(.init(stage: .moshing, fraction: 1))
        try checkCancelled()

        // 3. Decode back, re-attaching the untouched audio — the override when
        //    there is one, otherwise the video's own track. CFR output is what
        //    refills the held frames and keeps sync.
        let audio: URL? = request.audioSource ?? (info.hasAudio ? request.input : nil)
        // A trim moves the video's start, so whichever audio is muxed back has
        // to be seeked by the same amount. This used to apply only to an
        // override track, on the reasoning that it was laid against the
        // original timeline — but so is the video's own track, which was
        // left playing from zero against video starting at the in point.
        // Trim had no UI until now, so nothing ever exercised it.
        let audioStart = request.trim?.lowerBound ?? 0

        let mix: FFmpegTool.OutputMix? = request.mix < 0.999
            ? FFmpegTool.OutputMix(source: request.input, trim: request.trim,
                                   width: doc.width, height: doc.height,
                                   amount: request.mix)
            : nil

        try tool.decodeMoshed(avi: moshedAVI,
                              audioFrom: audio,
                              audioStart: audioStart,
                              output: request.output,
                              frameRate: doc.frameRate,
                              mix: mix,
                              token: token) { f in
            progress(.init(stage: .decoding, fraction: f))
        }

        progress(.init(stage: .done, fraction: 1))
        return RenderReport(frameCount: doc.frameCount, opCount: ops.count,
                            keyframesBefore: keysBefore, keyframesAfter: keysAfter,
                            duration: Date().timeIntervalSince(start),
                            output: request.output)
    }
}
