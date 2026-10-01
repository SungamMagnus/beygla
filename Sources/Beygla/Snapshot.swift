import AVFoundation
import AppKit
import MoshCore

/// `Beygla --open clip.mp4 --snapshot out.png` sets up a representative
/// project, renders a preview, and writes a picture of its own window.
///
/// The window draws itself into a bitmap (`cacheDisplay`), which needs no
/// Screen Recording permission — unlike capturing the screen. The one thing
/// that does not draw that way is the video layer, so a frame of the result is
/// decoded and laid over the player for the capture.
@MainActor
enum Snapshot {
    static func runIfRequested(_ model: AppModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        Task { await run(model, to: out) }
    }

    private static func run(_ model: AppModel, to out: URL) async {
        // Give the clip time to load and its audio time to be analysed.
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        model.rules = [
            MoshRule(kind: .bloom, source: .audio, band: .low, duration: 0.5),
            MoshRule(kind: .stutter, source: .audio, band: .low, duration: 0.25,
                     activeRegions: [ActiveRegion(start: 3.6, end: 7.5)]),
            MoshRule(kind: .glide, source: .audio, band: .low, duration: 0.3,
                     activeRegions: [ActiveRegion(start: 0.5, end: 3.4)]),
        ]
        if !model.vectorEngineMissing {
            model.vectorRules = [VectorRule(kind: .zoom, source: .audio, band: .low, duration: 0.4)]
        }
        model.smear = 0.8
        model.inPoint = 0.8
        model.outPoint = 7.2

        let preview = FileManager.default.temporaryDirectory
            .appendingPathComponent("beygla-snapshot-\(UUID().uuidString).mp4")
        model.render(to: preview, preview: true)
        while model.isRendering { try? await Task.sleep(nanoseconds: 200_000_000) }

        // A frame of the result well into a smear, laid over the player.
        let at = 2.2
        model.showPlayback(.result, startAt: at)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        model.player.pause()
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: preview))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        if let (cg, _) = try? await gen.image(at: CMTime(seconds: at - (model.inPoint ?? 0),
                                                       preferredTimescale: 600)) {
            model.snapshotFrame = NSImage(cgImage: cg, size: .zero)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)

        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("snapshot: no window\n".utf8)); exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
        print("snapshot written to \(out.path)")
        exit(0)
    }
}
