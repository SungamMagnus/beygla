import AVFoundation
import AppKit
import Combine
import Foundation
import MoshCore
import SwiftUI

/// Which file the player currently holds. Kept explicit so the transport can
/// say which one you are watching — comparing a mosh against its source is the
/// whole job, and guessing is no use.
public enum PlaybackSource: String, Hashable, Sendable {
    case source, result
}

@MainActor
public final class AppModel: ObservableObject {
    // MARK: Source

    @Published public var videoURL: URL?
    /// An audio file standing in for the video's own track. It drives the onset
    /// analysis, plays back against the video, and is muxed into the render.
    @Published public private(set) var audioURL: URL?
    @Published public private(set) var playbackSource: PlaybackSource = .source
    /// The file the player is actually holding, named so the transport can say
    /// so outright rather than leaving it to be inferred from the picture.
    @Published public private(set) var playbackName: String = "—"
    @Published public private(set) var playbackError: String?
    @Published public var info: VideoInfo?
    @Published public var loadError: String?

    /// Peak envelope of the source audio, for drawing the waveform.
    @Published public var envelope: [Float] = []
    /// Onset-detection curve, drawn under the waveform so the sensitivity
    /// slider has something visible to act on.
    @Published public var fluxCurve: [Float] = []
    @Published public var analysing = false

    // MARK: Triggers

    @Published public var triggerSource: TriggerSource = .audio {
        didSet {
            syncMIDILifecycle()
            if triggerSource == .sync {
                // A tempo grid is generated, not performed, so there is
                // nothing to arm.
                if isArmed { setArmed(false) }
                regenerateSyncEvents()
            }
        }
    }

    // MARK: Sync

    @Published public var syncSettings = SyncSettings() {
        didSet {
            if triggerSource == .sync || events.contains(where: { $0.source == .sync }) {
                regenerateSyncEvents()
            }
        }
    }
    private var tapTimes: [Double] = []

    /// Replace the grid's hits with a fresh set for the current settings.
    /// Only `.sync` events are touched — analysed onsets, hand-placed
    /// triggers and anything captured live stay where they are.
    public func regenerateSyncEvents() {
        events.removeAll { $0.source == .sync }
        guard let d = info?.duration, d > 0 else { return }
        events += SyncGrid.events(settings: syncSettings, duration: d)
        events.sort { $0.time < $1.time }
    }

    /// Tap along to set the tempo. Taps more than two seconds apart start
    /// a new count; the last eight are averaged.
    public func tapTempo() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = tapTimes.last, now - last > 2.0 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst(tapTimes.count - 8) }
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0 - $1 }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let bpm = (60 / mean * 10).rounded() / 10
        syncSettings.bpm = min(max(bpm, SyncSettings.bpmRange.lowerBound),
                               SyncSettings.bpmRange.upperBound)
    }

    public var tapCount: Int { tapTimes.count }

    /// Put beat 1 under the playhead.
    public func setDownbeatAtPlayhead() {
        syncSettings.offset = timelinePlayheadTime
    }

    /// How many effects listen to something other than the selected source.
    public var effectsOnOtherSources: Int {
        rules.filter { $0.source != triggerSource }.count
            + vectorRules.filter { $0.source != triggerSource }.count
    }

    /// Point every effect at one source. Switching the panel to Sync does not
    /// do this by itself: effects keep listening to whatever they were set
    /// to, so audio-driven and grid-driven effects can run in the same
    /// render. This is the explicit way to move them all at once.
    public func moveAllEffects(to source: TriggerSource) {
        let band: OnsetBand? = source == .audio ? onsetSettings.band : nil
        for i in rules.indices { rules[i].source = source; rules[i].band = band }
        for i in vectorRules.indices { vectorRules[i].source = source; vectorRules[i].band = band }
    }

    // MARK: Keyboard

    private var keyMonitor: Any?

    /// Space plays, I and O set the range.
    ///
    /// These are a local event monitor rather than menu-item shortcuts. A
    /// bare-letter menu shortcut is matched before the focused view sees the
    /// key, so it would swallow a space or an "o" typed into the BPM field.
    /// The monitor checks first and lets the key through when text is being
    /// edited. Local monitors run synchronously on the main thread during
    /// event dispatch, which is what makes `assumeIsolated` correct here — it
    /// is the audio tap's real-time thread where that promise was false.
    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case " ": self.togglePlay(); return true
                case "i": self.setInPoint(); return true
                case "o": self.setOutPoint(); return true
                default: return false
                }
            }
            return handled ? nil : event
        }
    }

    // MARK: In and out

    /// Where the render starts and stops, in seconds on the source. Either
    /// can be unset, meaning the start or end of the clip.
    @Published public var inPoint: Double?
    @Published public var outPoint: Double?
    public static let minTrimLength = 0.1

    public func setInPoint() {
        let t = timelinePlayheadTime
        inPoint = t
        // Setting In past Out clears Out, the way an edit suite does, rather
        // than leaving an inverted range that renders nothing.
        if let o = outPoint, o < t + Self.minTrimLength { outPoint = nil }
    }

    public func setOutPoint() {
        let t = timelinePlayheadTime
        outPoint = t
        if let i = inPoint, i > t - Self.minTrimLength { inPoint = nil }
    }

    /// Drag the in point, keeping it before Out and inside the clip.
    public func moveInPoint(to t: Double) {
        let hi = (outPoint ?? info?.duration ?? t) - Self.minTrimLength
        inPoint = min(max(0, t), max(0, hi))
    }

    /// Drag the out point, keeping it after In and inside the clip.
    public func moveOutPoint(to t: Double) {
        let lo = (inPoint ?? 0) + Self.minTrimLength
        outPoint = max(min(info?.duration ?? t, t), lo)
    }

    // MARK: Effect order

    /// Move an effect up or down its chain. Order is processing order: an
    /// effect works on what the ones above it produced.
    public func moveRule(_ id: UUID, by delta: Int) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard rules.indices.contains(j) else { return }
        rules.swapAt(i, j)
    }

    public func moveVectorRule(_ id: UUID, by delta: Int) {
        guard let i = vectorRules.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard vectorRules.indices.contains(j) else { return }
        vectorRules.swapAt(i, j)
    }

    /// Which family runs first: vector effects on the clean picture, then
    /// frame effects (true), or frame effects first and vectors after.
    @Published public var vectorsFirst = true

    public func clearInOut() {
        inPoint = nil
        outPoint = nil
    }

    /// The range a render covers, or nil for the whole clip.
    public var trimRange: ClosedRange<Double>? {
        guard inPoint != nil || outPoint != nil, let d = info?.duration else { return nil }
        let lo = max(0, inPoint ?? 0)
        let hi = min(d, outPoint ?? d)
        return hi - lo >= Self.minTrimLength ? lo ... hi : nil
    }

    // MARK: Mix

    /// How much of the moshed picture shows over the clean source, 0...1.
    @Published public var mix: Double = 1

    // MARK: Smear

    /// Seconds the damage lingers after an effect ends before a clean
    /// keyframe resets the picture; nil is "never", the default.
    @Published public var smear: Double? = nil
    public static let maxSmear: Double = 8
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
    /// Empty on launch: no effect is assumed. Every rule on the panel is one
    /// someone chose to add.
    @Published public var rules: [MoshRule] = []
    /// The second effect family — motion vectors rewritten inside frames.
    /// Empty by default: it needs the vector engine (ffgac/ffedit), which is
    /// a separate optional download, so a project that never touches this
    /// renders exactly as it always did.
    @Published public var vectorRules: [VectorRule] = []
    @Published public var moshSettings = MoshSettings()

    /// While armed, live audio and MIDI hits are written into `events` at the
    /// player's current time — play the clip, perform the mosh, then render it.
    @Published public var isArmed = false
    @Published public var liveHitFlash: Date?

    // MARK: Transport

    @Published public var currentTime: Double = 0
    @Published public var isPlaying = false

    // MARK: Timeline zoom
    //
    // 1 shows the whole clip; higher values narrow the visible window so a
    // long file can be edited in detail. `timelineOffset` is the start of
    // that window, in seconds — the two together define exactly what the
    // timeline currently shows, and both the zoom slider and trackpad
    // pinch/pan gestures drive the same pair of numbers.
    public static let maxTimelineZoom: Double = 200

    @Published public var timelineZoom: Double = 1 {
        didSet { clampTimelineOffset() }
    }
    @Published public var timelineOffset: Double = 0 {
        didSet { clampTimelineOffset() }
    }

    public var timelineVisibleDuration: Double {
        max(0.05, (info?.duration ?? 0.001) / max(1, timelineZoom))
    }

    public func resetTimelineZoom() {
        timelineZoom = 1
        timelineOffset = 0
    }

    /// Zoom around a fixed point in time — the point under the cursor for a
    /// trackpad pinch, or the playhead for the slider — so the moment being
    /// looked at stays under the cursor instead of the window recentering on
    /// zero every time.
    public func setTimelineZoom(_ newZoom: Double, anchoredAt anchorTime: Double) {
        let clamped = min(max(1, newZoom), Self.maxTimelineZoom)
        let oldVisible = timelineVisibleDuration
        let fraction = oldVisible > 0 ? (anchorTime - timelineOffset) / oldVisible : 0
        timelineZoom = clamped
        let newVisible = timelineVisibleDuration
        timelineOffset = anchorTime - fraction * newVisible
    }

    public func panTimeline(bySeconds delta: Double) {
        timelineOffset += delta
    }

    private func clampTimelineOffset() {
        let total = info?.duration ?? 0
        let visible = timelineVisibleDuration
        let maxOffset = max(0, total - visible)
        if timelineOffset < 0 { timelineOffset = 0 }
        if timelineOffset > maxOffset { timelineOffset = maxOffset }
    }

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
    public private(set) var vectorTool: FFglitchTool?
    public var ffmpegMissing: Bool { tool == nil }
    public var vectorEngineMissing: Bool { vectorTool == nil }
    /// Which ffmpeg is doing the work and what it will encode with — worth
    /// stating, because a bundled LGPL build has no libx264 and reaches for
    /// VideoToolbox instead.
    public var ffmpegSummary: String { tool?.capabilities.summary ?? "not found" }

    private var pcm: [Float] = []
    private var rawFlux: [Float] = []
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var statusObserver: AnyCancellable?
    private var pipeline: RenderPipeline?
    private let sampleRate = 44100

    public init() {
        tool = FFmpegTool.locate(bundledIn: Bundle.main.resourceURL)
        vectorTool = FFglitchTool.locate(bundledIn: Bundle.main.resourceURL)

        // AudioInput and MIDIInput publish their own state. Without forwarding
        // it, the level meter and the device list would sit frozen: SwiftUI is
        // watching AppModel, and nothing on AppModel changes when a nested
        // object does.
        audioInput.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        midiInput.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        audioInput.onOnset = { [weak self] strength in
            self?.recordLiveHit(strength: strength, source: .audio, note: nil)
        }
        midiInput.onNote = { [weak self] note in
            self?.recordLiveHit(strength: Double(note.velocity) / 127.0,
                                source: .midi, note: note.number)
        }

        installKeyboardShortcuts()

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

        resetTimelineZoom()
        clearInOut()
        resultTimeOffset = 0
        if triggerSource == .sync { regenerateSyncEvents() }
        showPlayback(.source, preserveTime: false)
        Task { await analyseTrack() }
    }

    /// Point the analysis and the render at a different audio file. Passing nil
    /// hands both back to the video's own track.
    public func loadAudio(url: URL?) {
        audioURL = url
        previewURL = nil
        lastReport = nil
        showPlayback(.source, preserveTime: true)
        Task { await analyseTrack() }
    }

    /// The file the onset detector listens to: the override when there is one.
    private var analysisSource: URL? { audioURL ?? videoURL }

    /// Decode the source audio once, then keep the flux curve around so moving
    /// the sensitivity slider is instant.
    public func analyseTrack() async {
        guard let tool, let url = analysisSource,
              audioURL != nil || info?.hasAudio == true else {
            envelope = []; fluxCurve = []; rawFlux = []; pcm = []
            events.removeAll { $0.source == .audio }
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
        // Replace only the analysed onsets. This used to reassign `events`
        // wholesale, so nudging the sensitivity knob wiped every hand-placed
        // and live-captured trigger along with them.
        events.removeAll { $0.source == .audio && $0.band != nil }
        events += onsets.map {
            TriggerEvent(time: $0.time, strength: $0.strength,
                         source: .audio, band: onsetSettings.band)
        }
        events.sort { $0.time < $1.time }
    }

    // MARK: - Live capture

    public func setArmed(_ armed: Bool) {
        guard !(armed && triggerSource == .sync) else { return }
        isArmed = armed
        if armed {
            // Live hits replace analysed ones — you are performing the mosh now.
            events.removeAll { $0.source == .audio && $0.band != nil }
            if triggerSource == .audio { audioInput.start() }
            if triggerSource == .midi { midiInput.start() }
        } else {
            audioInput.stop()
            // The MIDI client stays open while the MIDI tab is showing, so the
            // device list and Learn keep working between takes.
            if triggerSource != .midi { midiInput.stop() }
        }
    }

    private func syncMIDILifecycle() {
        if triggerSource == .midi {
            midiInput.start()
        } else if !isArmed {
            midiInput.stop()
        }
    }

    private func recordLiveHit(strength: Double, source: TriggerSource, note: Int?) {
        liveHitFlash = Date()
        guard isArmed else { return }
        let t = timelinePlayheadTime
        guard t.isFinite, t >= 0 else { return }
        events.append(TriggerEvent(time: t, strength: strength, source: source, note: note))
        events.sort { $0.time < $1.time }
    }

    public func addManualTrigger(at time: Double) {
        events.append(TriggerEvent(time: time, strength: 1.0, source: .manual))
        events.sort { $0.time < $1.time }
    }

    public func clearTriggers() { events.removeAll() }

    // MARK: - Where each effect is live

    /// Paint a span on a rule's lane. Until a rule has one, it is live
    /// everywhere; the first region painted is what starts restricting it.
    public func addRegion(to ruleID: UUID, from: Double, to: Double) {
        guard let i = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        guard abs(to - from) > 0.02 else { return }
        rules[i].activeRegions.append(ActiveRegion(start: from, end: to))
        rules[i].activeRegions.sort { $0.start < $1.start }
    }

    public func removeRegion(from ruleID: UUID, at time: Double) {
        guard let i = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[i].activeRegions.removeAll { $0.contains(time) }
    }

    /// Back to live everywhere.
    public func clearRegions(for ruleID: UUID) {
        guard let i = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[i].activeRegions.removeAll()
    }

    // Same three, for a vector rule's lane. Kept as a twin rather than a
    // shared generic — see the note on VectorRuleRow.
    public func addVectorRegion(to ruleID: UUID, from: Double, to: Double) {
        guard let i = vectorRules.firstIndex(where: { $0.id == ruleID }) else { return }
        guard abs(to - from) > 0.02 else { return }
        vectorRules[i].activeRegions.append(ActiveRegion(start: from, end: to))
        vectorRules[i].activeRegions.sort { $0.start < $1.start }
    }

    public func removeVectorRegion(from ruleID: UUID, at time: Double) {
        guard let i = vectorRules.firstIndex(where: { $0.id == ruleID }) else { return }
        vectorRules[i].activeRegions.removeAll { $0.contains(time) }
    }

    // MARK: - Transport

    public func togglePlay() {
        if player.rate == 0 {
            // The loaded file's own length, which for a trimmed result is
            // shorter than the source's.
            let d = player.currentItem?.duration.seconds ?? info?.duration ?? 0
            if d.isFinite, d > 0, currentTime >= d - 0.05 { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
    }

    /// Where the playhead is on the *source*. A trimmed result file starts at
    /// zero but begins at the in point, so while it is playing its own time
    /// is offset by where its render began. The timeline, the timecode, live
    /// capture and In/Out all work in this one frame of reference, so a
    /// moment means the same thing whichever file is loaded.
    public var timelinePlayheadTime: Double {
        playbackSource == .result ? currentTime + resultTimeOffset : currentTime
    }

    /// Source-timeline start of the result currently loaded — the in point
    /// it was rendered with, not the current one, which may since have moved.
    @Published public private(set) var resultTimeOffset: Double = 0

    /// Seek to a moment on the source timeline, whichever file is loaded.
    public func seek(to time: Double) {
        let local = playbackSource == .result ? time - resultTimeOffset : time
        player.seek(to: CMTime(seconds: max(0, local), preferredTimescale: 600),
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
        request.vectorRules = vectorRules
        request.audioSource = audioURL
        request.settings = moshSettings
        // In/out and Mix apply to Preview and Render alike: a preview of the
        // range you are working on, at the mix you will render with.
        let trim = trimRange
        request.trim = trim
        request.mix = mix
        request.smear = smear
        request.vectorsFirst = vectorsFirst
        // A preview trades resolution for turnaround; the mosh itself is
        // identical, so what you see is what the full render will do.
        request.previewWidth = preview ? 640 : nil
        request.quality = preview ? 5 : 3

        let pipeline = RenderPipeline(tool: tool, vectorTool: vectorTool)
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
                    // Show the thing that was just made, from just before the
                    // first trigger, and roll. Rendering and then leaving a
                    // paused first frame on screen is how this managed to look
                    // like it had done nothing twice over.
                    // The result's frame 0 is the in point it was rendered
                    // with; record that before switching so the playhead
                    // conversion uses this render's offset, not whatever
                    // In is set to by the time someone looks.
                    self.resultTimeOffset = trim?.lowerBound ?? 0
                    self.showPlayback(.result,
                                      startAt: self.firstInterestingTime(within: trim),
                                      autoPlay: true)
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

    /// Swap what the player is holding.
    ///
    /// `startAt` overrides the preserved playhead, and `autoPlay` starts it
    /// rolling regardless of whether it was rolling before. Both matter after a
    /// render: the first frame of a clip is its protected keyframe, so it is
    /// byte-for-byte the same picture in the source and the result. Landing
    /// there, paused, is indistinguishable from nothing having happened.
    public func showPlayback(_ source: PlaybackSource, preserveTime: Bool = true,
                             startAt: Double? = nil, autoPlay: Bool = false) {
        let resume = autoPlay || isPlaying
        // Both `startAt` and the preserved playhead are source-timeline times;
        // convert into the target file's own time.
        let sourceTime = startAt ?? (preserveTime ? timelinePlayheadTime : 0)
        let at = source == .result ? sourceTime - resultTimeOffset : sourceTime

        Task {
            let item: AVPlayerItem?
            switch source {
            case .source:
                item = await makeSourceItem()
                playbackName = audioURL == nil
                    ? (videoURL?.lastPathComponent ?? "—")
                    : "\(videoURL?.lastPathComponent ?? "—") + \(audioURL!.lastPathComponent)"
            case .result:
                item = previewURL.map { AVPlayerItem(url: $0) }
                playbackName = previewURL?.lastPathComponent ?? "—"
            }
            guard let item else { return }

            playbackSource = source
            playbackError = nil
            player.replaceCurrentItem(with: item)

            // An item that cannot be read leaves the last picture on screen,
            // which looks exactly like a swap that did not happen. Say so.
            observeStatus(of: item)

            await player.seek(to: CMTime(seconds: max(0, at), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            if resume { player.play() }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                self?.playbackError = item.error?.localizedDescription
                    ?? "The player could not read this file."
            }
    }

    /// Where to drop the playhead so a render is judged on a moment that
    /// actually differs: just before the first trigger inside the range
    /// that was rendered. Source-timeline seconds.
    public func firstInterestingTime(within range: ClosedRange<Double>?) -> Double {
        let lo = range?.lowerBound ?? 0
        let hi = range?.upperBound ?? .infinity
        guard let first = events.map(\.time).filter({ $0 >= lo && $0 < hi }).min() else { return lo }
        return max(lo, first - 0.4)
    }

    /// The source as you are cutting it: the video's picture, with the override
    /// audio in place of its own track when one is loaded. Built as a
    /// composition so the two play together without rendering anything.
    private func makeSourceItem() async -> AVPlayerItem? {
        guard let videoURL else { return nil }
        guard let audioURL else { return AVPlayerItem(url: videoURL) }

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        do {
            let videoDuration = try await videoAsset.load(.duration)
            guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first
            else { return AVPlayerItem(url: videoURL) }

            let composition = AVMutableComposition()
            if let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                                          of: videoTrack, at: .zero)
                track.preferredTransform = try await videoTrack.load(.preferredTransform)
            }

            // Clamp to the picture: a track longer than the clip would stretch
            // the timeline past the frames that exist.
            if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
               let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioDuration = try await audioAsset.load(.duration)
                let span = CMTimeMinimum(videoDuration, audioDuration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: span),
                                          of: audioTrack, at: .zero)
            }
            return AVPlayerItem(asset: composition)
        } catch {
            return AVPlayerItem(url: videoURL)
        }
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
