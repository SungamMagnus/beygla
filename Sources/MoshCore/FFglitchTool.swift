import Foundation

public enum FFglitchError: Error, LocalizedError {
    case notInstalled
    case scriptFailed(log: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The vector-effect engine (ffgac/ffedit) was not found. "
                 + "Run tools/build-ffglitch.sh, or use the bitstream effects, which need no extra tool."
        case .scriptFailed(let log):
            let tail = log.split(separator: "\n").suffix(10).joined(separator: "\n")
            return "Vector pass failed:\n\(tail)"
        }
    }
}

/// Wraps `ffgac` and `ffedit` — the FFglitch fork of ffmpeg that can export a
/// frame's motion vectors as JSON, run a script over them, and re-encode with
/// the edited vectors instead of the real ones.
///
/// This is a genuine decode/edit/re-encode pass, unlike `MoshEngine`'s byte
/// surgery, so it needs an encode step of its own. `ffgac` (ffglitch's own
/// ffmpeg, built with `-mpv_flags +nopimb+forcemv`) is used only for that one
/// step —
/// forcing a motion vector onto every macroblock, including ones a normal
/// encoder would mark "skip" because nothing moved. Everything before and
/// after stays on Beygla's regular bundled ffmpeg, which has the full format
/// support this narrowly-built one deliberately lacks.
public final class FFglitchTool: @unchecked Sendable {
    public let ffgac: URL
    public let ffedit: URL

    public init(ffgac: URL, ffedit: URL) {
        self.ffgac = ffgac
        self.ffedit = ffedit
    }

    public static func locate(bundledIn resourceDir: URL? = nil) -> FFglitchTool? {
        let beside = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath().deletingLastPathComponent()

        for dir in [resourceDir, beside].compactMap({ $0 }) {
            let a = dir.appendingPathComponent("ffgac")
            let b = dir.appendingPathComponent("ffedit")
            if FileManager.default.isExecutableFile(atPath: a.path),
               FileManager.default.isExecutableFile(atPath: b.path) {
                return FFglitchTool(ffgac: a, ffedit: b)
            }
        }
        for p in FFmpegTool.searchPaths {
            let a = URL(fileURLWithPath: p).appendingPathComponent("ffgac")
            let b = URL(fileURLWithPath: p).appendingPathComponent("ffedit")
            if FileManager.default.isExecutableFile(atPath: a.path),
               FileManager.default.isExecutableFile(atPath: b.path) {
                return FFglitchTool(ffgac: a, ffedit: b)
            }
        }
        return nil
    }

    /// Encode raw planar YUV420p to an MPEG-4 elementary stream with a motion
    /// vector forced onto every macroblock, then run `script` over those
    /// vectors and re-encode the result to `output`.
    ///
    /// `quality` follows FFmpeg's `-qscale:v` convention (lower is better).
    public func moshVectors(rawYUV: URL, width: Int, height: Int, frameRate: Double,
                            script: String, quality: Int, token: ProcessToken? = nil,
                            output: URL) throws {
        let work = output.deletingLastPathComponent()
        let encoded = work.appendingPathComponent("vec-encoded-\(UUID().uuidString).m4v")
        let scriptFile = work.appendingPathComponent("vec-script-\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: encoded)
                try? FileManager.default.removeItem(at: scriptFile) }

        try script.write(to: scriptFile, atomically: true, encoding: .utf8)

        // Step 1: raw YUV -> mpeg4 elementary stream, motion vector forced on
        // every macroblock so there is always something for the script to
        // rewrite, even where the source content is not actually moving.
        try run(ffgac, [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "yuv420p",
            "-s", "\(width)x\(height)", "-r", String(frameRate),
            "-i", rawYUV.path,
            // forcemv puts a vector on every macroblock; nopimb is what
            // keeps a "skip" macroblock from coming back with no vector at
            // all (a null cell in the exported grid) despite that — leaving
            // it out crashes every script the moment it hits one, since none
            // of them expect a hole in the grid.
            "-mpv_flags", "+nopimb+forcemv",
            "-qscale:v", String(quality),
            "-g", "999999", "-bf", "0",
            "-vcodec", "mpeg4", "-f", "rawvideo",
            encoded.path,
        ], token: token)

        // Step 2: export motion vectors, run the script, re-encode. `-f mv:0`
        // selects the motion-vector feature on stream 0; without it ffedit
        // refuses to run at all.
        try run(ffedit, [
            "-i", encoded.path,
            "-f", "mv:0",
            "-s", scriptFile.path,
            "-o", output.path,
        ], token: token)
    }

    @discardableResult
    private func run(_ tool: URL, _ args: [String], token: ProcessToken? = nil) throws {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice

        if let token, !token.adopt(p) { throw CancellationError() }
        defer { token?.release() }

        try p.run()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        if token?.isCancelled == true { throw CancellationError() }
        guard p.terminationStatus == 0 else { throw FFglitchError.scriptFailed(log: log) }
    }
}
