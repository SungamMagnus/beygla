import Accelerate
import Foundation

/// A detected transient in an audio signal.
public struct Onset: Hashable, Sendable {
    public var time: Double      // seconds
    public var strength: Double  // 0...1, how far above threshold it peaked

    public init(time: Double, strength: Double) {
        self.time = time
        self.strength = strength
    }
}

/// Which slice of the spectrum to listen to. Picking a band is what lets one
/// video react to the kick while another reacts to the hats.
public enum OnsetBand: String, Codable, CaseIterable, Identifiable, Sendable {
    case full, low, mid, high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .full: return "Full range"
        case .low: return "Low (kick)"
        case .mid: return "Mid (snare / body)"
        case .high: return "High (hats)"
        }
    }

    public var hertz: ClosedRange<Double> {
        switch self {
        case .full: return 20 ... 20_000
        case .low: return 20 ... 140
        case .mid: return 140 ... 2_000
        case .high: return 4_000 ... 16_000
        }
    }
}

public struct OnsetSettings: Codable, Sendable {
    /// 0...1. Higher means more onsets get through.
    public var sensitivity: Double = 0.5
    public var band: OnsetBand = .low
    /// Minimum gap between onsets, in seconds. Stops a single hit from firing
    /// three times as it decays.
    public var holdOff: Double = 0.12

    public init(sensitivity: Double = 0.5, band: OnsetBand = .low, holdOff: Double = 0.12) {
        self.sensitivity = sensitivity
        self.band = band
        self.holdOff = holdOff
    }
}

/// Spectral-flux onset detection.
///
/// Flux — the sum of positive frame-to-frame change in each magnitude bin —
/// spikes when energy suddenly appears, which is what a drum hit is. The
/// threshold adapts to a running median so a quiet passage and a loud one are
/// judged on their own terms rather than against one fixed level.
public enum OnsetDetector {
    public static let windowSize = 1024
    public static let hopSize = 256

    /// Compute the raw flux curve. Exposed separately so the UI can draw it
    /// under the waveform.
    public static func fluxCurve(pcm: [Float], sampleRate: Int, band: OnsetBand) -> [Float] {
        guard pcm.count > windowSize else { return [] }

        let log2n = vDSP_Length(log2(Double(windowSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let half = windowSize / 2
        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        // Bin range for the chosen band.
        let binHz = Double(sampleRate) / Double(windowSize)
        let lo = max(1, Int(band.hertz.lowerBound / binHz))
        let hi = min(half - 1, Int(band.hertz.upperBound / binHz))
        guard lo < hi else { return [] }

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: windowSize)

        var flux: [Float] = []
        flux.reserveCapacity((pcm.count - windowSize) / hopSize + 1)

        var pos = 0
        while pos + windowSize <= pcm.count {
            pcm.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + pos, 1, window, 1, &windowed, 1, vDSP_Length(windowSize))
            }

            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }

            // Positive spectral difference over the band only.
            var sum: Float = 0
            for k in lo ... hi {
                let d = magnitudes[k] - previous[k]
                if d > 0 { sum += d }
            }
            flux.append(sum)
            previous = magnitudes
            pos += hopSize
        }

        return flux
    }

    public static func analyze(pcm: [Float], sampleRate: Int, settings: OnsetSettings) -> [Onset] {
        let flux = fluxCurve(pcm: pcm, sampleRate: sampleRate, band: settings.band)
        return pickPeaks(flux: flux, sampleRate: sampleRate, settings: settings)
    }

    /// Pick onsets out of a flux curve.
    ///
    /// Peaks are ranked by **prominence** — how far a local maximum stands above
    /// the running median around it — and sensitivity selects what fraction of
    /// that ranking to keep. Thresholding the flux directly, which is the
    /// obvious approach, gives a knob that does nothing across most of its
    /// travel: on sparse percussive material the local median sits near zero, so
    /// a multiple of it is near zero too, and every candidate clears it at once.
    /// Ranking makes the control monotonic over its whole range instead.
    public static func pickPeaks(flux: [Float], sampleRate: Int, settings: OnsetSettings) -> [Onset] {
        guard flux.count > 8 else { return [] }

        let secondsPerFrame = Double(hopSize) / Double(sampleRate)
        let halfWin = max(4, Int(0.33 / secondsPerFrame))
        let peak = flux.max() ?? 0
        guard peak > 0 else { return [] }

        // 1. Every local maximum, with how far it rises above its neighbourhood.
        var indices: [Int] = []
        var prominences: [Float] = []
        for i in 1 ..< (flux.count - 1) {
            let v = flux[i]
            guard v > flux[i - 1], v >= flux[i + 1], v > peak * 0.002 else { continue }
            let lo = max(0, i - halfWin)
            let hi = min(flux.count, i + halfWin)
            var neighbourhood = Array(flux[lo ..< hi])
            neighbourhood.sort()
            let prominence = v - neighbourhood[neighbourhood.count / 2]
            if prominence > 0 {
                indices.append(i)
                prominences.append(prominence)
            }
        }
        guard !prominences.isEmpty else { return [] }

        // 2. Keep the most prominent fraction. The curve is deliberately steep
        //    at the bottom: the difference between "only the downbeats" and
        //    "the backbeat too" deserves more of the knob than the difference
        //    between "almost everything" and "everything".
        let s = max(0, min(1, settings.sensitivity))
        let keepFraction = 0.012 + 0.988 * pow(s, 1.7)
        let ranked = prominences.sorted(by: >)
        let cutIndex = min(ranked.count - 1,
                           max(0, Int((Double(ranked.count) * keepFraction).rounded()) - 1))
        // Widen the cut so it never falls between hits of near-equal strength.
        // A steady four-to-the-floor has eight nearly identical kicks; a strict
        // fraction would keep four of them and drop the rest arbitrarily, which
        // is musically wrong however defensible the ranking is.
        let cutoff = ranked[cutIndex] * 0.75
        let strongest = ranked[0]

        // 3. Hold-off, keeping the strongest hit in each window rather than
        //    whichever one happened to arrive first.
        var kept: [Onset] = []
        for (n, i) in indices.enumerated() where prominences[n] >= cutoff {
            let time = (Double(i) * Double(hopSize) + Double(windowSize) / 2) / Double(sampleRate)
            let strength = Double(min(1, prominences[n] / max(strongest, 1e-6)))
            if let last = kept.last, time - last.time < settings.holdOff {
                if strength > last.strength {
                    kept[kept.count - 1] = Onset(time: time, strength: strength)
                }
                continue
            }
            kept.append(Onset(time: time, strength: strength))
        }
        return kept
    }
}

/// Streaming counterpart for live audio input.
///
/// The offline detector can look ahead to compute a median; a live one cannot,
/// so it tracks a decaying running average of flux instead and fires when the
/// current frame jumps well clear of it.
public final class LiveOnsetDetector: @unchecked Sendable {
    // `settings` is written from whichever thread owns the AudioInput object
    // (the main actor, via a SwiftUI-driven Knob) and read every hop from
    // AVAudioEngine's own real-time tap thread — a genuine cross-thread
    // shared-mutable-state race, not a hypothetical one, since both sides
    // fire independently of each other. A lock around a two-Double struct
    // costs nothing worth measuring next to the FFT this class is already
    // doing per hop, so it is simpler to just make the property safe than to
    // reason about who is allowed to touch it when.
    private let settingsLock = NSLock()
    private var _settings: OnsetSettings
    public var settings: OnsetSettings {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _settings }
        set { settingsLock.lock(); _settings = newValue; settingsLock.unlock() }
    }

    private let sampleRate: Int
    private var previousMagnitudes: [Float]
    private var average: Float = 0
    private var lastFireTime: Double = -.infinity
    private var ring: [Float] = []
    private let fftSetup: FFTSetup?
    private let log2n: vDSP_Length
    private let window: [Float]
    private let binLo: Int
    private let binHi: Int

    /// Most recent flux value, normalised for metering.
    public private(set) var level: Float = 0

    public init(sampleRate: Int, settings: OnsetSettings) {
        self.sampleRate = sampleRate
        self._settings = settings
        let n = OnsetDetector.windowSize
        log2n = vDSP_Length(log2(Double(n)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        window = w
        previousMagnitudes = [Float](repeating: 0, count: n / 2)
        let binHz = Double(sampleRate) / Double(n)
        binLo = max(1, Int(settings.band.hertz.lowerBound / binHz))
        binHi = min(n / 2 - 1, Int(settings.band.hertz.upperBound / binHz))
    }

    deinit { if let s = fftSetup { vDSP_destroy_fftsetup(s) } }

    /// Feed a buffer of mono samples. Returns the strength of an onset that
    /// started in this buffer, or nil.
    public func process(_ samples: [Float], hostTime: Double) -> Double? {
        guard let setup = fftSetup, binLo < binHi else { return nil }
        ring.append(contentsOf: samples)

        let n = OnsetDetector.windowSize
        let half = n / 2
        var fired: Double? = nil

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)

        while ring.count >= n {
            ring.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(n))
            }

            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }

            var sum: Float = 0
            for k in binLo ... binHi {
                let d = magnitudes[k] - previousMagnitudes[k]
                if d > 0 { sum += d }
            }
            previousMagnitudes = magnitudes
            level = sum

            let s = max(0, min(1, settings.sensitivity))
            let multiplier = Float(0.9 + 7.1 * (1 - s) * (1 - s))
            let threshold = average * multiplier
            if sum > threshold, average > 0,
               hostTime - lastFireTime >= settings.holdOff {
                lastFireTime = hostTime
                fired = Double(min(1, (sum - threshold) / max(threshold, 1e-6)))
            }
            // Asymmetric smoothing: rise quickly with the music, fall back slowly
            // so the tail of a hit does not re-arm the detector.
            average = sum > average ? average * 0.7 + sum * 0.3 : average * 0.96 + sum * 0.04

            ring.removeFirst(min(OnsetDetector.hopSize, ring.count))
        }

        return fired
    }
}
