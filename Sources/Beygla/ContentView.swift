import AVFoundation
import AppKit
import MoshCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Sungam.ink18).frame(height: Sungam.hairline)
            HStack(spacing: 0) {
                stage
                Rectangle().fill(Sungam.ink18).frame(width: Sungam.hairline)
                Inspector().frame(width: 420)
            }
        }
        .background(Sungam.paper)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.load(url: url) }
            }
            return true
        }
        .alert("Render failed", isPresented: Binding(
            get: { model.renderError != nil },
            set: { if !$0 { model.renderError = nil } }
        )) {
            Button("OK", role: .cancel) { model.renderError = nil }
        } message: {
            Text(model.renderError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Wordmark(text: "Beygla", size: Sungam.textLg, color: Sungam.ink85)

            // The material, then what listens to it: video, audio, trigger
            // source — the three choices everything else hangs off.
            HeaderSlot(label: "Video") {
                LatchButton(label: model.videoURL?.lastPathComponent ?? "Open…") { openVideo() }
                    .help(model.info.map { i in
                        "\(i.width)×\(i.height)  \(String(format: "%.3f", i.frameRate)) fps  \(String(format: "%.2f", i.duration))s"
                    } ?? "Open a video")
            }

            HeaderSlot(label: "Audio") {
                LatchButton(label: model.audioURL?.lastPathComponent ?? "From video") { openAudio() }
                    .help(model.audioURL == nil
                          ? "Load a separate track to drive detection, play against the picture and mux into the render"
                          : "Overrides the video's own track")
                if model.audioURL != nil {
                    LatchButton(label: "×") { model.loadAudio(url: nil) }
                }
            }

            HeaderSlot(label: "Trigger") {
                DropdownLatch(label: model.triggerSource.displayName, color: Sungam.coral,
                              options: TriggerSource.allCases.map { ($0, $0.displayName) },
                              selection: model.triggerSource) { model.triggerSource = $0 }
            }

            Spacer()

            if model.isRendering {
                HStack(spacing: 10) {
                    Text(model.renderStage.uppercased())
                        .font(Sungam.mono(Sungam.textSm))
                        .tracking(Sungam.textSm * Sungam.scale * 0.05)
                        .foregroundStyle(Sungam.ink62)
                    SegmentMeter(level: model.renderProgress, color: Sungam.steel, segments: 16)
                        .frame(width: 140)
                    LatchButton(label: "Cancel") { model.cancelRender() }
                }
            } else {
                // Mix is the one global amount: how much of the mosh shows
                // over the clean source in what Preview and Render produce.
                Text("MIX")
                    .font(Sungam.mono(Sungam.text2xs))
                    .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.ink45)
                Fader(value: $model.mix, color: Sungam.steel, width: 90)
                Text(String(format: "%.0f%%", model.mix * 100))
                    .font(Sungam.mono(Sungam.text2xs).monospacedDigit())
                    .foregroundStyle(model.mix < 0.999 ? Sungam.steel : Sungam.ink62)
                    .frame(width: 34 * Sungam.scale, alignment: .leading)
                    .onTapGesture(count: 2) { model.mix = 1 }
                // Smear: how long an effect's damage lingers after it ends.
                // The top of the fader is "never", the old behaviour.
                Text("SMEAR")
                    .font(Sungam.mono(Sungam.text2xs))
                    .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.ink45)
                Fader(value: smearFraction, color: Sungam.steel, width: 90)
                Text(model.smear.map { String(format: "%.1fs", $0) } ?? "∞")
                    .font(Sungam.mono(Sungam.text2xs).monospacedDigit())
                    .foregroundStyle(model.smear == nil ? Sungam.ink62 : Sungam.steel)
                    .frame(width: 34 * Sungam.scale, alignment: .leading)
                    .onTapGesture(count: 2) { model.smear = nil }
                LatchButton(label: "Preview", enabled: canRender) { render(preview: true) }
                LatchButton(label: "Render", color: Sungam.steel, filled: canRender,
                            enabled: canRender) { render(preview: false) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Sungam.paper)
    }

    private var canRender: Bool {
        model.videoURL != nil && !model.ffmpegMissing && !model.events.isEmpty
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 0) {
            ZStack {
                Sungam.stage
                PlayerView(player: model.player)
                    .padding(12)

                if let frame = model.snapshotFrame {
                    Image(nsImage: frame).resizable().aspectRatio(contentMode: .fit)
                        .padding(12)
                }

                if model.centrePickRule != nil { centrePickLayer }

                if model.videoURL == nil {
                    VStack(spacing: 10) {
                        Wordmark(text: "Drop a video", size: Sungam.textLg, color: Sungam.ink38)
                        if model.ffmpegMissing {
                            Text("No ffmpeg. Build a bundled one with ./tools/build-ffmpeg.sh, or brew install ffmpeg")
                                .font(Sungam.mono(Sungam.textBase))
                                .foregroundStyle(Sungam.amber)
                        }
                    }
                }

                if model.isArmed {
                    VStack {
                        HStack(spacing: 6) {
                            Spacer()
                            Lamp(on: true, color: Sungam.amber, size: 8)
                            Text("ARMED")
                                .font(Sungam.mono(Sungam.textSm, weight: .bold))
                                .tracking(Sungam.textSm * Sungam.scale * 0.12)
                                .foregroundStyle(Sungam.amber)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Sungam.stage.opacity(0.8))
                        .padding(10)
                        Spacer()
                    }
                }
            }

            Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)

            // Everything below the picture: one transport row, the timeline,
            // and a quiet footer that only says what is useful right now.
            VStack(spacing: 10) {
                transport
                TriggerBar()
                TimelineView()
                timelineZoomRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(Sungam.paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// While a radial effect waits for its centre: a crosshair on the picture
    /// and a click that sets it. The picture is aspect-fitted inside the
    /// stage's padding, so the click is mapped through that fitted rectangle.
    private var centrePickLayer: some View {
        GeometryReader { geo in
            let box = CGRect(x: 12, y: 12, width: geo.size.width - 24, height: geo.size.height - 24)
            let video = fittedRect(in: box)
            let rule = model.vectorRules.first { $0.id == model.centrePickRule }
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { p in
                        guard video.contains(p) else { model.centrePickRule = nil; return }
                        model.setCentre(x: (p.x - video.minX) / video.width,
                                        y: (p.y - video.minY) / video.height)
                    }
                if let rule {
                    let c = CGPoint(x: video.minX + video.width * rule.centreX,
                                    y: video.minY + video.height * rule.centreY)
                    Path { p in
                        p.move(to: CGPoint(x: c.x - 14, y: c.y)); p.addLine(to: CGPoint(x: c.x + 14, y: c.y))
                        p.move(to: CGPoint(x: c.x, y: c.y - 14)); p.addLine(to: CGPoint(x: c.x, y: c.y + 14))
                    }
                    .stroke(rule.kind.signalColor, lineWidth: 2)
                    .allowsHitTesting(false)
                }
                Text("CLICK THE PICTURE TO SET \((rule?.kind.displayName ?? "").uppercased())'S CENTRE")
                    .font(Sungam.mono(Sungam.textSm, weight: .bold))
                    .tracking(Sungam.textSm * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.lilacText)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Sungam.stage.opacity(0.85))
                    .padding(20)
                    .allowsHitTesting(false)
            }
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
        }
    }

    private func fittedRect(in box: CGRect) -> CGRect {
        guard let i = model.info, i.width > 0, i.height > 0 else { return box }
        let aspect = Double(i.width) / Double(i.height)
        var w = box.width, h = w / aspect
        if h > box.height { h = box.height; w = h * aspect }
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// Zoom is felt exponentially — the jump from 1x to 2x and the jump from
    /// 100x to 200x should feel like the same amount of turn on the slider —
    /// so the Fader's linear 0...1 travel is mapped through a log curve
    /// rather than straight onto the zoom value.
    private var zoomFraction: Binding<Double> {
        Binding(
            get: {
                let z = max(1, model.timelineZoom)
                return log(z) / log(AppModel.maxTimelineZoom)
            },
            set: { frac in
                let z = exp(max(0, min(1, frac)) * log(AppModel.maxTimelineZoom))
                model.setTimelineZoom(z, anchoredAt: model.timelinePlayheadTime)
            }
        )
    }

    /// Squared so the short end — where most of the useful settings are —
    /// gets most of the travel. The last stretch of the fader is "never".
    private var smearFraction: Binding<Double> {
        Binding(
            get: {
                guard let s = model.smear else { return 1 }
                return min(0.97, (s / AppModel.maxSmear).squareRoot())
            },
            set: { f in
                model.smear = f >= 0.98 ? nil : AppModel.maxSmear * f * f
            })
    }

    private var timelineZoomRow: some View {
        HStack(spacing: 10) {
            Text("ZOOM")
                .font(Sungam.mono(Sungam.text2xs))
                .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                .foregroundStyle(Sungam.ink45)

            Fader(value: zoomFraction, color: Sungam.steel, width: 130)

            Text(model.timelineZoom < 1.05 ? "1X" : String(format: "%.1fX", model.timelineZoom))
                .font(Sungam.mono(Sungam.text2xs).monospacedDigit())
                .foregroundStyle(Sungam.ink62)
                .frame(width: 36 * Sungam.scale, alignment: .leading)

            if model.timelineZoom > 1.001 {
                LatchButton(label: "Reset") { model.resetTimelineZoom() }
            }

            Spacer()

            readout

            Spacer()

            // In and out — steel, the render-chain colour, as on the timeline.
            Text("RANGE")
                .font(Sungam.mono(Sungam.text2xs))
                .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                .foregroundStyle(Sungam.ink45)

            Text(rangeReadout)
                .font(Sungam.mono(Sungam.text2xs).monospacedDigit())
                .foregroundStyle(model.trimRange == nil ? Sungam.ink45 : Sungam.steel)

            LatchButton(label: "In  I", enabled: model.videoURL != nil) { model.setInPoint() }
            LatchButton(label: "Out  O", enabled: model.videoURL != nil) { model.setOutPoint() }
            if model.inPoint != nil || model.outPoint != nil {
                LatchButton(label: "×") { model.clearInOut() }
            }
        }
    }

    private var rangeReadout: String {
        guard let r = model.trimRange else { return "whole clip" }
        return String(format: "%.2f–%.2fs  (%.2fs)", r.lowerBound, r.upperBound,
                      r.upperBound - r.lowerBound)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            if model.isPlaying {
                LatchButton(label: "Stop", color: Sungam.coral, filled: true) {
                    model.stopPlayback()
                }
            } else {
                LatchButton(label: "Play", color: Sungam.coral, filled: model.videoURL != nil,
                            enabled: model.videoURL != nil) { model.playFromStart() }
                // Steel, like the range itself: plays In to Out and stops.
                // Only offered once there is a range to play.
                if model.inPoint != nil || model.outPoint != nil {
                    LatchButton(label: "Play range", color: Sungam.steel) { model.playFromIn() }
                }
            }

            Text("\(timecode(model.timelinePlayheadTime)) / \(timecode(model.info?.duration ?? 0))")
                .font(Sungam.mono(Sungam.textBase).monospacedDigit())
                .foregroundStyle(Sungam.ink85)

            Rectangle().fill(Sungam.ink18)
                .frame(width: Sungam.hairline, height: 14)

            Selector(options: [(PlaybackSource.source, "Source"), (.result, "Result")],
                     selection: Binding(
                        get: { model.playbackSource },
                        set: { model.showPlayback($0) }
                     ),
                     color: Sungam.steel,
                     isEnabled: { $0 == .source ? model.videoURL != nil
                                                : model.previewURL != nil })
                .frame(width: 150)

            if let u = model.previewURL, model.playbackSource == .result {
                LatchButton(label: "Reveal") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }

            Spacer()

            LabelValue(label: "Triggers", value: "\(model.events.count)",
                       color: model.events.isEmpty ? Sungam.ink38 : Sungam.coral)
            if !model.events.isEmpty {
                LatchButton(label: "×") { model.clearTriggers() }
            }
        }
    }

    /// The render's measured result, stated as numbers rather than a checkmark.
    private var readout: some View {
        HStack(spacing: 14) {
            if let r = model.lastReport {
                LabelValue(label: "Frames", value: "\(r.frameCount)", color: Sungam.steel,
                           size: Sungam.text2xs)
                LabelValue(label: "Ops", value: "\(r.opCount)", color: Sungam.teal,
                           size: Sungam.text2xs)
                LabelValue(label: "Keyframes",
                           value: "\(r.keyframesBefore)→\(r.keyframesAfter)",
                           color: Sungam.coral, size: Sungam.text2xs)
                LabelValue(label: "Took", value: String(format: "%.1fs", r.duration),
                           color: Sungam.ink62, size: Sungam.text2xs)
            } else {
                Text("Click the Triggers track to add · drag a box to select · pinch to zoom")
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink38)
                    .lineLimit(1)
            }
            if let e = model.playbackError {
                Text(e).font(Sungam.mono(Sungam.textSm)).foregroundStyle(Sungam.amber)
                    .lineLimit(1)
            }
        }
    }

    private func timecode(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00.00" }
        let m = Int(t) / 60, s = Int(t) % 60, cs = Int((t - floor(t)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    // MARK: Actions

    private func openAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.loadAudio(url: url) }
    }

    private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.load(url: url) }
    }

    private func render(preview: Bool) {
        guard let src = model.videoURL else { return }
        if preview {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("beygla-preview-\(UUID().uuidString).mp4")
            model.render(to: out, preview: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + "-beygla.mp4"
        if panel.runModal() == .OK, let out = panel.url {
            model.render(to: out, preview: false)
        }
    }
}

/// A small caption sitting before its control in the header, so the row reads
/// as labelled fields rather than a run of anonymous buttons.
private struct HeaderSlot<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(Sungam.mono(Sungam.text2xs))
                .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                .foregroundStyle(Sungam.ink45)
            content
        }
    }
}
