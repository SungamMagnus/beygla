import AVFoundation
import AppKit
import MoshCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                stage
                Divider().overlay(Theme.stroke)
                Inspector()
                    .frame(width: 330)
            }
        }
        .background(Theme.bg)
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

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("MOSHBOX")
                .font(.system(size: 13, weight: .heavy)).tracking(2)
                .foregroundStyle(Theme.accent)

            Button("Open…") { openVideo() }
                .buttonStyle(.bordered)

            if let url = model.videoURL {
                Text(url.lastPathComponent)
                    .font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                if let i = model.info {
                    Text("\(i.width)×\(i.height) · \(String(format: "%.2f", i.frameRate)) fps · \(String(format: "%.1f", i.duration))s")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.dim.opacity(0.7))
                }
            }

            Spacer()

            if model.isRendering {
                HStack(spacing: 8) {
                    ProgressView(value: model.renderProgress)
                        .frame(width: 120).controlSize(.small)
                    Text(model.renderStage).font(.caption).foregroundStyle(Theme.dim)
                    Button("Cancel") { model.cancelRender() }.buttonStyle(.bordered)
                }
            } else {
                Button("Preview") { render(preview: true) }
                    .buttonStyle(.bordered)
                    .disabled(!canRender)
                Button("Render…") { render(preview: false) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!canRender)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var canRender: Bool {
        model.videoURL != nil && !model.ffmpegMissing && !model.events.isEmpty
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 10) {
            ZStack {
                PlayerView(player: model.player)
                    .background(Color.black)

                if model.videoURL == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 34)).foregroundStyle(Theme.dim)
                        Text("Drop a video here")
                            .font(.callout).foregroundStyle(Theme.dim)
                        if model.ffmpegMissing {
                            Text("ffmpeg not found — install it with `brew install ffmpeg`")
                                .font(.caption).foregroundStyle(Theme.hot)
                        }
                    }
                }

                if model.isArmed {
                    VStack {
                        HStack {
                            Spacer()
                            Label("ARMED", systemImage: "record.circle")
                                .font(.caption.bold())
                                .foregroundStyle(Theme.hot)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(10)
                        }
                        Spacer()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))

            transport
            TimelineView()
            hint
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.bordered)
            .disabled(model.videoURL == nil)
            .keyboardShortcut(.space, modifiers: [])

            Text(timecode(model.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.text)

            Text("/ \(timecode(model.info?.duration ?? 0))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.dim)

            Divider().frame(height: 16)

            Button("Source") { model.playSource() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.videoURL == nil)
            Button("Result") { model.playPreview() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.previewURL == nil)

            Spacer()

            if let r = model.lastReport {
                Text("\(r.frameCount) frames · \(r.opCount) ops · keyframes \(r.keyframesBefore)→\(r.keyframesAfter) · \(String(format: "%.1f", r.duration))s")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
            }

            Text("\(model.events.count) triggers")
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.events.isEmpty ? Theme.dim : Theme.accent)
            Button("Clear") { model.clearTriggers() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.events.isEmpty)
        }
    }

    private var hint: some View {
        Text("Drag the timeline to scrub · double-click to drop a trigger at the playhead · space to play")
            .font(.caption2).foregroundStyle(Theme.dim.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .appendingPathComponent("moshbox-preview-\(UUID().uuidString).mp4")
            model.render(to: out, preview: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + "-moshed.mp4"
        if panel.runModal() == .OK, let out = panel.url {
            model.render(to: out, preview: false)
        }
    }
}
