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
                Inspector().frame(width: 460)
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
            Wordmark(text: "Beygla", size: Sungam.textXl, color: Sungam.ink)

            LatchButton(label: "Open") { openVideo() }

            if let url = model.videoURL {
                Text(url.lastPathComponent)
                    .font(Sungam.mono(Sungam.textBase))
                    .foregroundStyle(Sungam.ink62)
                    .lineLimit(1)
                if let i = model.info {
                    Text("\(i.width)×\(i.height)  \(String(format: "%.3f", i.frameRate)) FPS  \(String(format: "%.2f", i.duration))S")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(Sungam.ink38)
                }
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
                LatchButton(label: "Preview", enabled: canRender) { render(preview: true) }
                LatchButton(label: "Render", color: Sungam.steel, filled: canRender,
                            enabled: canRender) { render(preview: false) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Sungam.paper)
    }

    private var canRender: Bool {
        model.videoURL != nil && !model.ffmpegMissing && !model.events.isEmpty
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 12) {
            ZStack {
                PlayerView(player: model.player)
                    .background(Sungam.ink)

                if model.videoURL == nil {
                    VStack(spacing: 10) {
                        Wordmark(text: "Drop a video", size: Sungam.textLg, color: Sungam.ink38)
                        if model.ffmpegMissing {
                            Text("ffmpeg not found — brew install ffmpeg")
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
                        .background(Sungam.paper)
                        .padding(10)
                        Spacer()
                    }
                }
            }
            .overlay(Rectangle().stroke(Sungam.ink28, lineWidth: Sungam.hairline))

            transport
            TimelineView()
            readout
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            LatchButton(label: model.isPlaying ? "Stop" : "Play",
                        color: Sungam.coral,
                        filled: model.isPlaying,
                        enabled: model.videoURL != nil) { model.togglePlay() }

            Text("\(timecode(model.currentTime)) / \(timecode(model.info?.duration ?? 0))")
                .font(Sungam.mono(Sungam.textBase))
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

            Text(model.playbackName)
                .font(Sungam.mono(Sungam.text2xs))
                .foregroundStyle(model.playbackSource == .result ? Sungam.steel : Sungam.ink45)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)

            LatchButton(label: "Reveal", enabled: model.previewURL != nil) {
                if let u = model.previewURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }

            Spacer()

            LabelValue(label: "Triggers", value: "\(model.events.count)",
                       color: model.events.isEmpty ? Sungam.ink38 : Sungam.coral)
            LatchButton(label: "Clear", enabled: !model.events.isEmpty) { model.clearTriggers() }
        }
    }

    /// The render's measured result, stated as numbers rather than a checkmark.
    private var readout: some View {
        HStack(spacing: 16) {
            if let r = model.lastReport {
                LabelValue(label: "Frames", value: "\(r.frameCount)", color: Sungam.steel,
                           size: Sungam.textSm)
                LabelValue(label: "Ops", value: "\(r.opCount)", color: Sungam.teal,
                           size: Sungam.textSm)
                LabelValue(label: "Keyframes",
                           value: "\(r.keyframesBefore)→\(r.keyframesAfter)",
                           color: Sungam.coral, size: Sungam.textSm)
                LabelValue(label: "Took", value: String(format: "%.1fs", r.duration),
                           color: Sungam.ink62, size: Sungam.textSm)
            } else {
                Text("Click the timeline to scrub. Double-click to place a trigger there — a hand-placed trigger fires every enabled effect.")
                    .font(Sungam.mono(Sungam.textSm))
                    .foregroundStyle(Sungam.ink38)
            }
            if let e = model.playbackError {
                Text(e).font(Sungam.mono(Sungam.textSm)).foregroundStyle(Sungam.amber)
            }
            Spacer()
        }
    }

    private func timecode(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00.00" }
        let m = Int(t) / 60, s = Int(t) % 60, cs = Int((t - floor(t)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    // MARK: Actions

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
