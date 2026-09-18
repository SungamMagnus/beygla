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
    public var settings: MoshSettings
    /// Force keyframes at trigger times so `bloom` has something to strip.
    /// Without this a clip encoded with a single keyframe has nothing to bloom.
    public var seedKeyframesAtTriggers: Bool
    public var quality: Int
    public var previewWidth: Int?
    public var trim: ClosedRange<Double>?
    public var seed: UInt64

    public init(input: URL, output: URL, events: [TriggerEvent], rules: [MoshRule],
                audioSource: URL? = nil,
                settings: MoshSettings = .init(), seedKeyframesAtTriggers: Bool = true,
                quality: Int = 3, previewWidth: Int? = nil,
                trim: ClosedRange<Double>? = nil, seed: UInt64 = 0x4D05_4842) {
        self.input = input
        self.output = output
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
    private let token = ProcessToken()

    public init(tool: FFmpegTool) { self.tool = tool }

    /// Kills the running ffmpeg immediately rather than waiting for the current
    /// stage to finish on its own.
    public func cancel() { token.cancel() }

    private func checkCancelled() throws {
        if token.isCancelled { throw RenderError.cancelled }
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

        try tool.encodeMoshable(input: request.input, output: rawAVI, options: opts,
                                token: token) { f in
            progress(.init(stage: .encoding, fraction: f))
        }
        try checkCancelled()

        // 2. Byte surgery.
        progress(.init(stage: .moshing, fraction: 0))
        let data = try Data(contentsOf: rawAVI, options: .mappedIfSafe)
        let doc = try AVIDocument(data: data)
        let keysBefore = doc.keyframeIndices.count

        let trimBase = request.trim?.lowerBound ?? 0
        let shifted = request.events.map { e -> TriggerEvent in
            var c = e
            c.time -= trimBase
            return c
        }
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
        // A trim moves the video's start, and an external track is laid against
        // the original timeline, so the audio has to be seeked by the same amount.
        let audioStart = request.audioSource != nil ? (request.trim?.lowerBound ?? 0) : 0
        try tool.decodeMoshed(avi: moshedAVI,
                              audioFrom: audio,
                              audioStart: audioStart,
                              output: request.output,
                              frameRate: doc.frameRate,
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
