import AVFoundation
import Combine
import Foundation
import MoshCore

/// Live audio input, tapped and run through the streaming onset detector.
///
/// This is the "audio in" trigger: point it at a mic, an interface, or a
/// loopback device carrying the track you are cutting to, and every transient
/// it hears becomes a trigger.
@MainActor
public final class AudioInput: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var level: Double = 0
    @Published public private(set) var lastHitAt: Date?
    @Published public var settings = OnsetSettings(sensitivity: 0.5, band: .low, holdOff: 0.12) {
        didSet { detector?.settings = settings; rebuildIfBandChanged(oldValue) }
    }
    @Published public private(set) var permissionDenied = false

    /// Called on the main actor for every detected onset, with strength 0...1.
    public var onOnset: ((Double) -> Void)?

    private let engine = AVAudioEngine()
    private var detector: LiveOnsetDetector?
    private var converter: AVAudioConverter?
    private var startHostTime: Double = 0

    public init() {}

    public func start() {
        guard !isRunning else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.permissionDenied = false
                    self.beginTap()
                } else {
                    self.permissionDenied = true
                }
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = 0
    }

    private func rebuildIfBandChanged(_ old: OnsetSettings) {
        guard old.band != settings.band, isRunning else { return }
        stop()
        beginTap()
    }

    private func beginTap() {
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else { return }

        let sampleRate = Int(hwFormat.sampleRate)
        let liveDetector = LiveOnsetDetector(sampleRate: sampleRate, settings: settings)
        detector = liveDetector
        startHostTime = CACurrentMediaTime()

        // AVAudioEngine calls this closure on its own real-time audio thread,
        // never the main actor — no tap runs there, ever. The previous
        // version reached for `self.detector` through `MainActor.assumeIsolated`,
        // a promise that the current thread actually is the main actor's,
        // which is simply false here; the runtime check backing that promise
        // trapped the instant a live source was armed. `liveDetector` is
        // captured directly instead, so the audio thread never touches a
        // MainActor-isolated property at all. It stays safe to call from here
        // because `LiveOnsetDetector` guards its one piece of state anything
        // else can reach (`settings`) with its own lock, and everything else
        // it holds is only ever touched from this same serial tap queue.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            let mono = Self.monoSamples(from: buffer)
            guard !mono.isEmpty else { return }

            var peak: Float = 0
            for s in mono { peak = max(peak, abs(s)) }

            let now = CACurrentMediaTime()
            let hit = liveDetector.process(mono, hostTime: now)

            guard let self else { return }
            Task { @MainActor in
                // Decay the meter smoothly so it reads like a VU rather than flickering.
                self.level = max(Double(peak), self.level * 0.82)
                if let strength = hit {
                    self.lastHitAt = Date()
                    self.onOnset?(strength)
                }
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }

        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: frames)) }

        var out = [Float](repeating: 0, count: frames)
        for c in 0 ..< channels {
            let p = data[c]
            for i in 0 ..< frames { out[i] += p[i] }
        }
        let scale = 1.0 / Float(channels)
        for i in 0 ..< frames { out[i] *= scale }
        return out
    }
}
