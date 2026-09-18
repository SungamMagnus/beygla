import AVFoundation
import Combine
import Foundation
import MoshCore
import SwiftUI

@MainActor
public final class AppModel: ObservableObject {
    // MARK: Source

    @Published public var videoURL: URL?
    @Published public var info: VideoInfo?
    @Published public var loadError: String?

    /// Peak envelope of the source audio, for drawing the waveform.
    @Published public var envelope: [Float] = []
    /// Onset-detection curve, drawn under the waveform so the sensitivity
    /// slider has something visible to act on.
    @Published public var fluxCurve: [Float] = []
    @Published public var analysing = false

    // MARK: Triggers

    @Published public var triggerSource: TriggerSource = .audio
    @Published public var onsetSettings = OnsetSettings(sensitivity: 0.5, band: .low, holdOff: 0.12) {
        didSet {
            audioInput.settings = onsetSettings
            if triggerSource == .audio && oldValue.band != onsetSettings.band {
                Task { await analyseTrack() }
            } else if triggerSource == .audio {
                recomputeOnsets()
            }
        }
    }
    @Published public var events: [TriggerEvent] = []
    @Published public var rules: [MoshRule] = MoshRule.defaultSet()
    @Published public var moshSettings = MoshSettings()

    /// While armed, live audio and MIDI hits are written into `events` at the
    /// player's current time — play the clip, perform the mosh, then render it.
    @Published public var isArmed = false
    @Published public var liveHitFlash: Date?

    // MARK: Transport

    @Published public var currentTime: Double = 0
    @Published public var isPlaying = false

    // MARK: Render

    @Published public var isRendering = false
    @Published public var renderStage: String = ""
    @Published public var renderProgress: Double = 0
    @Published public var lastReport: RenderReport?
    @Published public var renderError: String?
    @Published public var previewURL: URL?

    // MARK: Collaborators

    public let audioInput = AudioInput()
    public let midiInput = MIDIInput()
    public let player = AVPlayer()
    public private(set) var tool: FFmpegTool?
    public var ffmpegMissing: Bool { tool == nil }

    private var pcm: [Float] = []
    private var rawFlux: [Float] = []
    private var timeObserver: Any?
    private var pipeline: RenderPipeline?
    private let sampleRate = 44100

    public init() {
        tool = FFmpegTool.locate(bundledIn: Bundle.main.resourceURL)

        audioInput.onOnset = { [weak self] strength in
            self?.recordLiveHit(strength: strength, source: .audio, note: nil)
        }
        midiInput.onNote = { [weak self] note in
            self?.recordLiveHit(strength: Double(note.velocity) / 127.0,
                                source: .midi, note: note.number)
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    // MARK: - Loading

    public func load(url: URL) {
        videoURL = url
        loadError = nil
        previewURL = nil
        lastReport = nil
        events.removeAll()

        guard let tool else {
            loadError = FFmpegError.notInstalled.localizedDescription
            return
        }

        do {
            info = try tool.probe(url)
        } catch {
            loadError = error.localizedDescription
            return
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: .zero)
        Task { await analyseTrack() }
    }

    /// Decode the source audio once, then keep the flux curve around so moving
    /// the sensitivity slider is instant.
    public func analyseTrack() async {
        guard let tool, let url = videoURL, info?.hasAudio == true else {
            envelope = []; fluxCurve = []; rawFlux = []; pcm = []
            return
        }
        analysing = true
        defer { analysing = false }

        let band = onsetSettings.band
        let rate = sampleRate
        let samples: [Float]
        do {
            samples = try await Task.detached(priority: .userInitiated) {
                try tool.extractPCM(from: url, sampleRate: rate)
            }.value
        } catch {
            loadError = error.localizedDescription
            return
        }

        let flux = await Task.detached(priority: .userInitiated) {
            OnsetDetector.fluxCurve(pcm: samples, sampleRate: rate, band: band)
        }.value

        pcm = samples
        rawFlux = flux
        envelope = Self.peakEnvelope(samples, buckets: 2000)
        fluxCurve = Self.normalised(flux)
        recomputeOnsets()
    }

    /// Re-pick peaks from the cached flux curve. Cheap enough to run on every
    /// slider tick.
    public func recomputeOnsets() {
        guard !rawFlux.isEmpty else { return }
        let onsets = OnsetDetector.pickPeaks(flux: rawFlux, sampleRate: sampleRate,
                                             settings: onsetSettings)
        events = onsets.map {
            TriggerEvent(time: $0.time, strength: $0.strength,
                         source: .audio, band: onsetSettings.band)
        }
    }

    // MARK: - Live capture

    public func setArmed(_ armed: Bool) {
        isArmed = armed
        if armed {
            // Live hits replace analysed ones — you are performing the mosh now.
            events.removeAll { $0.source == .audio && $0.band != nil }
            if triggerSource == .audio { audioInput.start() }
            if triggerSource == .midi { midiInput.start() }
        } else {
            audioInput.stop()
            midiInput.stop()
        }
    }

    private func recordLiveHit(strength: Double, source: TriggerSource, note: Int?) {
        liveHitFlash = Date()
        guard isArmed else { return }
        let t = currentTime
        guard t.isFinite, t >= 0 else { return }
        events.append(TriggerEvent(time: t, strength: strength, source: source, note: note))
        events.sort { $0.time < $1.time }
    }

    public func addManualTrigger(at time: Double) {
        events.append(TriggerEvent(time: time, strength: 1.0, source: .manual))
        events.sort { $0.time < $1.time }
    }

    public func clearTriggers() { events.removeAll() }

    // MARK: - Transport

    public func togglePlay() {
        if player.rate == 0 {
            if let d = info?.duration, currentTime >= d - 0.05 { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
    }

    public func seek(to time: Double) {
        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Render

    public func render(to output: URL, preview: Bool) {
        guard let tool, let url = videoURL else { return }
        guard !isRendering else { return }

        isRendering = true
        renderError = nil
        renderProgress = 0
        renderStage = RenderStage.probing.rawValue

        var request = RenderRequest(input: url, output: output, events: events, rules: rules)
        request.settings = moshSettings
        // A preview trades resolution for turnaround; the mosh itself is
        // identical, so what you see is what the full render will do.
        request.previewWidth = preview ? 640 : nil
        request.quality = preview ? 5 : 3

        let pipeline = RenderPipeline(tool: tool)
        self.pipeline = pipeline

        Task.detached(priority: .userInitiated) {
            do {
                let report = try pipeline.run(request) { p in
                    Task { @MainActor in
                        self.renderStage = p.stage.rawValue
                        self.renderProgress = p.fraction
                    }
                }
                await MainActor.run {
                    self.isRendering = false
                    self.lastReport = report
                    self.previewURL = output
                    self.renderStage = RenderStage.done.rawValue
                }
            } catch {
                await MainActor.run {
                    self.isRendering = false
                    if !(error is RenderError) {
                        self.renderError = error.localizedDescription
                    }
                }
            }
        }
    }

    public func cancelRender() {
        pipeline?.cancel()
    }

    public func playPreview() {
        guard let url = previewURL else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: .zero)
        player.play()
    }

    public func playSource() {
        guard let url = videoURL else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: .zero)
    }

    // MARK: - Drawing helpers

    static func peakEnvelope(_ samples: [Float], buckets: Int) -> [Float] {
        guard !samples.isEmpty, buckets > 0 else { return [] }
        let per = max(1, samples.count / buckets)
        var out: [Float] = []
        out.reserveCapacity(buckets)
        var i = 0
        while i < samples.count {
            var peak: Float = 0
            let end = min(i + per, samples.count)
            for j in i ..< end { peak = max(peak, abs(samples[j])) }
            out.append(peak)
            i = end
        }
        return out
    }

    static func normalised(_ v: [Float]) -> [Float] {
        guard let m = v.max(), m > 0 else { return v }
        return v.map { $0 / m }
    }
}
