import Foundation

public struct VideoInfo: Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var duration: Double
    public var frameCount: Int
    public var hasAudio: Bool

    public var frameCountEstimate: Int {
        frameCount > 0 ? frameCount : Int((duration * frameRate).rounded())
    }
}

public enum FFmpegError: Error, LocalizedError {
    case notInstalled
    case failed(command: String, status: Int32, log: String)
    case badProbeOutput(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "ffmpeg and ffprobe were not found. Install them with `brew install ffmpeg`, "
                 + "or point Beygla at them in Settings."
        case .failed(let cmd, let status, let log):
            let tail = log.split(separator: "\n").suffix(12).joined(separator: "\n")
            return "ffmpeg \(cmd) failed (exit \(status)):\n\(tail)"
        case .badProbeOutput(let s):
            return "Could not read media info: \(s)"
        }
    }
}

/// Holds whichever ffmpeg process is running right now so it can be killed.
///
/// Checking a cancellation flag between pipeline stages is not cancelling: the
/// encode of a long clip is a single ffmpeg invocation that blocks for as long
/// as it takes, and a flag checked after it finishes has cancelled nothing. The
/// process itself has to be terminated.
public final class ProcessToken: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let p = current
        lock.unlock()
        p?.terminate()
    }

    /// Take ownership of a process that is about to run. A token cancelled
    /// before the process started kills it immediately rather than letting it
    /// slip through the gap.
    func adopt(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        current = p
        return true
    }

    func release() {
        lock.lock(); current = nil; lock.unlock()
    }
}

/// Thin wrapper over the ffmpeg/ffprobe binaries.
///
/// Beygla shells out rather than linking libav* because the moshing itself is
/// pure byte surgery — ffmpeg is only ever asked to do the two things it is
/// unambiguously good at: produce a clean MPEG-4 elementary stream, and decode
/// a deliberately broken one without giving up.
public final class FFmpegTool: @unchecked Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL
    /// What this particular binary can do. A bundled LGPL build has no libx264,
    /// so the deliverable is encoded with VideoToolbox instead; a Homebrew
    /// build usually has both. Probed once, because the answer decides every
    /// render command afterwards.
    public let capabilities: Capabilities

    public struct Capabilities: Sendable {
        public var hasLibX264: Bool
        public var hasVideoToolbox: Bool
        public var isBundled: Bool
        public var version: String

        /// The encoder used for the final file.
        public var videoEncoder: String {
            hasLibX264 ? "libx264" : (hasVideoToolbox ? "h264_videotoolbox" : "mpeg4")
        }

        public var summary: String {
            "\(isBundled ? "bundled" : "system") ffmpeg \(version) · \(videoEncoder)"
        }
    }

    public static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin",
    ]

    public init(ffmpeg: URL, ffprobe: URL, isBundled: Bool = false) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe

        let encoders = (try? FFmpegTool.capture(ffmpeg, ["-hide_banner", "-encoders"])) ?? ""
        let banner = (try? FFmpegTool.capture(ffmpeg, ["-version"])) ?? ""
        let version = banner
            .split(separator: "\n").first
            .flatMap { $0.split(separator: " ").dropFirst(2).first.map(String.init) } ?? "?"

        capabilities = Capabilities(
            hasLibX264: encoders.contains("libx264"),
            hasVideoToolbox: encoders.contains("h264_videotoolbox"),
            isBundled: isBundled,
            version: version)
    }

    /// Run a tool and return stdout, ignoring a non-zero exit.
    static func capture(_ tool: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    /// Look for the binaries next to the app first (a bundled copy), then in the
    /// usual places, then on PATH.
    public static func locate(bundledIn resourceDir: URL? = nil) -> FFmpegTool? {
        // A bundled copy wins. It is the one that is guaranteed to be there and
        // to behave the same on every machine, which matters more for a render
        // than the marginal quality of one encoder over another.
        if let dir = resourceDir {
            let a = dir.appendingPathComponent("ffmpeg")
            let b = dir.appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: a.path),
               FileManager.default.isExecutableFile(atPath: b.path) {
                return FFmpegTool(ffmpeg: a, ffprobe: b, isBundled: true)
            }
        }

        func find(_ name: String) -> URL? {
            for p in searchPaths {
                let u = URL(fileURLWithPath: p).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: u.path) { return u }
            }
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                for p in path.split(separator: ":") {
                    let u = URL(fileURLWithPath: String(p)).appendingPathComponent(name)
                    if FileManager.default.isExecutableFile(atPath: u.path) { return u }
                }
            }
            return nil
        }
        guard let a = find("ffmpeg"), let b = find("ffprobe") else { return nil }
        return FFmpegTool(ffmpeg: a, ffprobe: b, isBundled: false)
    }

    // MARK: - Probe

    public func probe(_ url: URL) throws -> VideoInfo {
        let out = try runCapturing(ffprobe, [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate,nb_frames:format=duration",
            "-of", "default=noprint_wrappers=1",
            url.path,
        ])

        var fields: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }

        guard let w = fields["width"].flatMap({ Int($0) }),
              let h = fields["height"].flatMap({ Int($0) }) else {
            throw FFmpegError.badProbeOutput(out)
        }

        var fps = 30.0
        if let r = fields["r_frame_rate"] {
            let p = r.split(separator: "/")
            if p.count == 2, let n = Double(p[0]), let d = Double(p[1]), d > 0 { fps = n / d }
        }
        let duration = fields["duration"].flatMap { Double($0) } ?? 0
        let frames = fields["nb_frames"].flatMap { Int($0) } ?? 0

        let audio = (try? runCapturing(ffprobe, [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=index", "-of", "csv=p=0", url.path,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        return VideoInfo(width: w, height: h, frameRate: fps, duration: duration,
                         frameCount: frames, hasAudio: !audio.isEmpty)
    }

    // MARK: - Encode

    public struct EncodeOptions: Sendable {
        /// Lower is better quality; 2–6 is a sensible range. Heavier quantisation
        /// gives chunkier, more visible mosh blocks, so this doubles as a look control.
        public var quality: Int = 3
        /// Downscale to this width (nil keeps native). Moshing is CPU-cheap but
        /// encoding is not, so previews use a small width.
        public var width: Int? = nil
        public var frameRate: Double? = nil
        /// Times (seconds) where a keyframe should be forced, giving `bloom` ops
        /// something to strip out.
        public var keyframeTimes: [Double] = []
        public var trim: ClosedRange<Double>? = nil

        public init() {}
    }

    /// Encode to the one format that can actually be moshed: MPEG-4 Part 2 in
    /// AVI, no B-frames, no scene-change keyframes, video only.
    public func encodeMoshable(input: URL, output: URL, options: EncodeOptions,
                               token: ProcessToken? = nil,
                               progress: ((Double) -> Void)? = nil) throws {
        var args = ["-y", "-hide_banner"]
        if let t = options.trim {
            args += ["-ss", String(t.lowerBound), "-to", String(t.upperBound)]
        }
        args += ["-i", input.path, "-an", "-sn", "-dn"]

        var filters: [String] = []
        if let w = options.width { filters.append("scale=\(w):-2:flags=bicubic") }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        if let fps = options.frameRate { args += ["-r", String(fps)] }

        args += [
            "-c:v", "mpeg4",
            "-q:v", String(options.quality),
            // No B-frames: they reference frames in both directions and turn
            // every mosh into unpredictable mush.
            "-bf", "0",
            // One keyframe at the start and nowhere else unless we ask.
            "-g", "999999",
            "-sc_threshold", "1000000000",
            "-pix_fmt", "yuv420p",
            "-fps_mode", "cfr",
        ]
        if !options.keyframeTimes.isEmpty {
            let expr = options.keyframeTimes.map { String(format: "%.4f", $0) }.joined(separator: ",")
            args += ["-force_key_frames", expr]
        }
        args.append(output.path)

        try run(ffmpeg, args, token: token, progress: progress)
    }

    // MARK: - Decode

    /// Decode the moshed AVI back to a normal deliverable.
    ///
    /// `-fps_mode cfr` is doing the load-bearing work here. Held frames appear in
    /// the AVI as skip VOPs that the decoder emits nothing for, leaving a gap in
    /// the presentation timeline; CFR output refills those gaps by repeating the
    /// last picture, which restores the exact original frame count and keeps the
    /// result locked to the original audio.
    public func decodeMoshed(avi: URL, audioFrom: URL?, audioStart: Double = 0,
                             output: URL, frameRate: Double, crf: Int = 18,
                             token: ProcessToken? = nil,
                             progress: ((Double) -> Void)? = nil) throws {
        var args = [
            "-y", "-hide_banner",
            "-fflags", "+genpts",
            "-err_detect", "ignore_err",
            "-i", avi.path,
        ]
        if let a = audioFrom {
            if audioStart > 0 { args += ["-ss", String(audioStart)] }
            args += ["-i", a.path]
        }

        args += ["-map", "0:v:0"]
        if audioFrom != nil { args += ["-map", "1:a:0?"] }

        args += ["-fps_mode", "cfr", "-r", String(frameRate)]

        if capabilities.hasLibX264 {
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", String(crf)]
        } else if capabilities.hasVideoToolbox {
            // VideoToolbox has no CRF. Its -q:v runs the other way — 1 is worst,
            // 100 is best — so the scale is inverted to keep one quality
            // argument meaning the same thing throughout the app.
            let q = max(20, min(95, 100 - crf * 2))
            args += ["-c:v", "h264_videotoolbox", "-q:v", String(q),
                     "-allow_sw", "1", "-realtime", "0"]
        } else {
            args += ["-c:v", "mpeg4", "-q:v", "3"]
        }

        args += ["-pix_fmt", "yuv420p", "-movflags", "+faststart"]
        if audioFrom != nil { args += ["-c:a", "aac", "-b:a", "192k", "-shortest"] }
        args.append(output.path)

        try run(ffmpeg, args, token: token, progress: progress)
    }

    // MARK: - Audio

    /// Pull mono float PCM out of a file for onset analysis.
    public func extractPCM(from url: URL, sampleRate: Int = 44100) throws -> [Float] {
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = [
            "-v", "error", "-i", url.path, "-vn",
            "-ac", "1", "-ar", String(sampleRate),
            "-f", "f32le", "-",
        ]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        var raw = Data()
        try p.run()
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            raw.append(chunk)
        }
        p.waitUntilExit()
        _ = err.fileHandleForReading.readDataToEndOfFile()

        guard p.terminationStatus == 0 || !raw.isEmpty else { return [] }

        let count = raw.count / MemoryLayout<Float>.size
        return raw.withUnsafeBytes { buf in
            Array(UnsafeBufferPointer(start: buf.baseAddress!.assumingMemoryBound(to: Float.self),
                                      count: count))
        }
    }

    // MARK: - Process plumbing

    @discardableResult
    func runCapturing(_ tool: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FFmpegError.failed(command: args.joined(separator: " "),
                                     status: p.terminationStatus,
                                     log: String(decoding: e, as: UTF8.self))
        }
        return String(decoding: o, as: UTF8.self)
    }

    /// Run ffmpeg, streaming stderr so `-progress`-free runs can still report
    /// roughly where they are by parsing `time=`.
    func run(_ tool: URL, _ args: [String], token: ProcessToken? = nil,
             progress: ((Double) -> Void)? = nil) throws {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice

        var log = ""
        var totalDuration: Double = 0
        let handle = err.fileHandleForReading

        if let token, !token.adopt(p) { throw CancellationError() }
        defer { token?.release() }

        try p.run()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            let s = String(decoding: chunk, as: UTF8.self)
            log += s
            if log.count > 200_000 { log = String(log.suffix(100_000)) }

            if totalDuration == 0, let d = Self.parseDuration(s) { totalDuration = d }
            if let cb = progress, totalDuration > 0, let t = Self.parseTime(s) {
                cb(min(1.0, t / totalDuration))
            }
        }
        p.waitUntilExit()

        // A terminated process exits non-zero; that is a cancellation, not a
        // failure, and must not surface as an error dialog.
        if token?.isCancelled == true { throw CancellationError() }

        guard p.terminationStatus == 0 else {
            throw FFmpegError.failed(command: args.joined(separator: " "),
                                     status: p.terminationStatus, log: log)
        }
        progress?(1.0)
    }

    static func parseDuration(_ s: String) -> Double? {
        guard let r = s.range(of: "Duration: ") else { return nil }
        return parseClock(String(s[r.upperBound...].prefix(11)))
    }

    static func parseTime(_ s: String) -> Double? {
        var latest: Double? = nil
        var search = s.startIndex ..< s.endIndex
        while let r = s.range(of: "time=", range: search) {
            if let v = parseClock(String(s[r.upperBound...].prefix(11))) { latest = v }
            search = r.upperBound ..< s.endIndex
        }
        return latest
    }

    static func parseClock(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
