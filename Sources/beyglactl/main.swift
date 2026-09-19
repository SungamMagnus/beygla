import Foundation
import MoshCore

// A thin command-line front end. The GUI and this share every line of the
// actual moshing, so if a render misbehaves it can be reproduced here.

/// Prints each render stage once, from whichever thread ffmpeg happens to be
/// pumping output on.
final class StageReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: RenderStage?

    func note(_ stage: RenderStage) {
        lock.lock()
        let changed = stage != last
        last = stage
        lock.unlock()
        if changed {
            FileHandle.standardError.write(Data("\(stage.rawValue)…\n".utf8))
        }
    }
}

func usage() -> Never {
    print("""
    beyglactl — Beygla command line

      beyglactl info <video>
          Show stream geometry and keyframe layout.

      beyglactl onsets <media> [--band low|mid|high|full] [--sens 0.5]
          Print detected transients.

      beyglactl render <video> <output.mp4> [options]
          --band low|mid|high|full   which band drives triggers (default low)
          --sens 0.0-1.0             onset sensitivity (default 0.5)
          --effect bloom|glide|echo|stutter|reverse|shuffle|freeze
          --dur 0.4                  effect length in seconds
          --width 640                downscale before moshing
          --quality 3                mpeg4 -q:v, higher = chunkier
          --audio track.wav          use this audio instead of the video's own
          --at 1.0,2.5,4.0           place triggers by hand at these seconds
                                     instead of detecting them
          --live 2.0-4.0,6.0-7.0     only let the effect fire inside these spans
          --purge                    strip every keyframe in the clip
          --vector-effect KIND       add a vector effect (needs ffgac/ffedit)
                                     sink|stop|invertReverse|mirror|vibrate|
                                     zoom|slamZoom|shear|delay|shift|noise
          --vector-dur 0.3           vector effect length in seconds
          --list-vector-effects      print all vector effects and exit
          --cancel-after 1.5         debug: cancel mid-render, to check that
                                     cancelling actually kills ffmpeg
    """)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }
let command = args.removeFirst()

guard let tool = FFmpegTool.locate() else {
    FileHandle.standardError.write(Data("error: \(FFmpegError.notInstalled.localizedDescription)\n".utf8))
    exit(2)
}
let vectorTool = FFglitchTool.locate()

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: "--\(name)") { args.remove(at: i); return true }
    return false
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i ... (i + 1))
    return v
}

do {
    switch command {
    case "list-vector-effects":
        for kind in VectorOpKind.allCases {
            print("\(kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                + "\(kind.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                + "from \(kind.source)")
        }

    case "info":
        guard let path = args.first else { usage() }
        let url = URL(fileURLWithPath: path)
        let info = try tool.probe(url)
        print("\(info.width)x\(info.height)  \(String(format: "%.3f", info.frameRate)) fps  "
            + "\(String(format: "%.2f", info.duration))s  ~\(info.frameCountEstimate) frames  "
            + "audio: \(info.hasAudio ? "yes" : "no")")

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("beyglactl-\(UUID().uuidString).avi")
        defer { try? FileManager.default.removeItem(at: work) }
        var opts = FFmpegTool.EncodeOptions()
        opts.width = 320
        try tool.encodeMoshable(input: url, output: work, options: opts)
        let doc = try AVIDocument(data: try Data(contentsOf: work, options: .mappedIfSafe))
        let types = doc.frames.map { $0.type.map(\.description) ?? "-" }.joined()
        print("moshable stream: \(doc.frameCount) frames, keyframes at \(doc.keyframeIndices)")
        print("picture types: \(types.prefix(120))\(types.count > 120 ? "…" : "")")
        if doc.hasBFrames { print("warning: stream contains B-frames") }
        if let vol = doc.frames.first(where: { $0.isKey }).flatMap({ MPEG4.parseVOL($0.payload) }) {
            print("VOL: time_increment_resolution=\(vol.timeIncrementResolution) "
                + "bits=\(vol.timeIncrementBits), skip VOP = "
                + MPEG4.makeSkipVOP(vol).map { String(format: "%02x", $0) }.joined())
        }

    case "onsets":
        guard let path = args.first else { usage() }
        args.removeFirst()
        var s = OnsetSettings()
        if let b = option("band"), let band = OnsetBand(rawValue: b) { s.band = band }
        if let v = option("sens"), let d = Double(v) { s.sensitivity = d }
        let pcm = try tool.extractPCM(from: URL(fileURLWithPath: path))
        guard !pcm.isEmpty else { print("no audio found"); exit(1) }
        let onsets = OnsetDetector.analyze(pcm: pcm, sampleRate: 44100, settings: s)
        print("\(onsets.count) onsets in \(String(format: "%.2f", Double(pcm.count) / 44100))s "
            + "(band \(s.band.rawValue), sensitivity \(s.sensitivity))")
        for o in onsets.prefix(60) {
            print(String(format: "  %7.3fs  %.2f", o.time, o.strength))
        }
        if onsets.count > 60 { print("  … \(onsets.count - 60) more") }

    case "render":
        guard args.count >= 2 else { usage() }
        let input = URL(fileURLWithPath: args.removeFirst())
        let output = URL(fileURLWithPath: args.removeFirst())

        var onsetSettings = OnsetSettings()
        if let b = option("band"), let band = OnsetBand(rawValue: b) { onsetSettings.band = band }
        if let v = option("sens"), let d = Double(v) { onsetSettings.sensitivity = d }
        let kind = option("effect").flatMap { MoshOpKind(rawValue: $0) } ?? .bloom
        let duration = option("dur").flatMap { Double($0) } ?? 0.4
        let width = option("width").flatMap { Int($0) }
        let quality = option("quality").flatMap { Int($0) } ?? 3
        let purge = flag("purge")
        let audioOverride = option("audio").map { URL(fileURLWithPath: $0) }
        let vectorKindRaw = option("vector-effect")
        let vectorDuration = option("vector-dur").flatMap { Double($0) } ?? 0.3

        // The detector listens to whatever will end up on the render.
        let manualTimes = option("at")?
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        let events: [TriggerEvent]
        if let times = manualTimes {
            events = times.map { TriggerEvent(time: $0, strength: 1.0, source: .manual) }
            print("placed \(events.count) triggers by hand")
        } else {
            let pcm = try tool.extractPCM(from: audioOverride ?? input)
            let onsets = pcm.isEmpty ? [] :
                OnsetDetector.analyze(pcm: pcm, sampleRate: 44100, settings: onsetSettings)
            print("detected \(onsets.count) onsets in the \(onsetSettings.band.rawValue) band"
                + (audioOverride.map { " of \($0.lastPathComponent)" } ?? ""))
            events = onsets.map {
                TriggerEvent(time: $0.time, strength: $0.strength, source: .audio,
                             band: onsetSettings.band)
            }
        }
        // Spans where the effect is live — the command-line form of painting a
        // lane on the timeline. Without any, it is live for the whole clip.
        let regions: [ActiveRegion] = (option("live")?.split(separator: ",") ?? [])
            .compactMap { spec in
                let p = spec.split(separator: "-")
                guard p.count == 2, let a = Double(p[0]), let b = Double(p[1]) else { return nil }
                return ActiveRegion(start: a, end: b)
            }
        if !regions.isEmpty {
            print("live only inside " + regions
                .map { String(format: "%.2f-%.2fs", $0.start, $0.end) }
                .joined(separator: ", "))
        }

        let rules = [MoshRule(kind: kind, source: .audio, band: onsetSettings.band,
                              duration: duration, activeRegions: regions)]

        var request = RenderRequest(input: input, output: output, events: events, rules: rules)
        request.audioSource = audioOverride
        request.settings = MoshSettings(purgeAllKeyframes: purge)

        if let raw = vectorKindRaw {
            guard let vKind = VectorOpKind(rawValue: raw) else {
                FileHandle.standardError.write(Data(
                    "error: unknown vector effect '\(raw)' — see --list-vector-effects\n".utf8))
                exit(1)
            }
            guard vectorTool != nil else {
                FileHandle.standardError.write(Data(
                    "error: \(FFglitchError.notInstalled.localizedDescription)\n".utf8))
                exit(1)
            }
            request.vectorRules = [VectorRule(kind: vKind, source: .audio,
                                              band: onsetSettings.band, duration: vectorDuration)]
        }
        request.quality = quality
        request.previewWidth = width

        let reporter = StageReporter()
        let pipeline = RenderPipeline(tool: tool, vectorTool: vectorTool)

        if let after = option("cancel-after").flatMap({ Double($0) }) {
            let started = Date()
            DispatchQueue.global().asyncAfter(deadline: .now() + after) {
                FileHandle.standardError.write(Data("cancelling…\n".utf8))
                pipeline.cancel()
            }
            do {
                _ = try pipeline.run(request) { p in reporter.note(p.stage) }
                print("render finished before the cancel landed")
            } catch {
                print(String(format: "cancelled after %.2fs (asked at %.2fs)",
                             Date().timeIntervalSince(started), after))
            }
            exit(0)
        }

        let report = try pipeline.run(request) { p in
            reporter.note(p.stage)
        }
        print("""
        rendered \(report.output.lastPathComponent)
          frames    \(report.frameCount)
          ops       \(report.opCount)
          keyframes \(report.keyframesBefore) -> \(report.keyframesAfter)
          took      \(String(format: "%.1f", report.duration))s
        """)

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
