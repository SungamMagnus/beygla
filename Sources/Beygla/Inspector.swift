import AppKit
import CoreMIDI
import MoshCore
import SwiftUI
import UniformTypeIdentifiers

struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                filesPanel
                sourcePanel
                if model.triggerSource == .audio { detectionPanel }
                if model.triggerSource == .midi { midiPanel }
                effectsPanel
                streamPanel
            }
            .padding(16)
        }
        .background(Sungam.paper)
    }

    // MARK: Files — neutral ink
    //
    // The source files are the material, not a stage of the signal, so this
    // panel takes no section colour. The palette stays reserved for what the
    // signal actually does.

    private var filesPanel: some View {
        PanelFrame(title: "Source", color: Sungam.ink38) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("VIDEO")
                        .font(Sungam.mono(Sungam.text2xs))
                        .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                        .foregroundStyle(Sungam.ink62)
                        .frame(width: 42 * Sungam.scale, alignment: .leading)
                    Text(model.videoURL?.lastPathComponent ?? "none")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(model.videoURL == nil ? Sungam.ink38 : Sungam.ink85)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    LatchButton(label: "Load") { openVideo() }
                }

                Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)

                HStack(spacing: 8) {
                    Text("AUDIO")
                        .font(Sungam.mono(Sungam.text2xs))
                        .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                        .foregroundStyle(Sungam.ink62)
                        .frame(width: 42 * Sungam.scale, alignment: .leading)
                    Text(model.audioURL?.lastPathComponent ?? "from video")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(model.audioURL == nil ? Sungam.ink38 : Sungam.ink85)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    LatchButton(label: "Load") { openAudio() }
                    LatchButton(label: "Clear", enabled: model.audioURL != nil) {
                        model.loadAudio(url: nil)
                    }
                }

                if model.audioURL != nil {
                    Text("Overrides the video's own track — it drives detection, plays against the picture, and is muxed into the render.")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(Sungam.ink45)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.load(url: url) }
    }

    private func openAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.loadAudio(url: url) }
    }

    // MARK: Source — coral, the trigger path

    private var sourcePanel: some View {
        PanelFrame(title: "Trigger source", color: Sungam.coral) {
            VStack(alignment: .leading, spacing: 10) {
                Selector(options: TriggerSource.allCases.map { ($0, $0.displayName) },
                         selection: $model.triggerSource,
                         color: Sungam.coral)

                Text(sourceBlurb)
                    .font(Sungam.mono(Sungam.textSm))
                    .foregroundStyle(Sungam.ink62)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if model.triggerSource != .manual {
                    HStack(spacing: 8) {
                        Lamp(on: model.isArmed, color: Sungam.amber, size: 9)
                        Latch(label: model.isArmed ? "Armed — disarm" : "Arm live capture",
                              on: Binding(
                                get: { model.isArmed },
                                set: { model.setArmed($0) }
                              ),
                              color: Sungam.amber)
                    }
                }
            }
        }
    }

    private var sourceBlurb: String {
        switch model.triggerSource {
        case .audio:
            return model.isArmed
                ? "Listening to live input. Play the clip; every transient lands as a trigger at the playhead."
                : "Transients in the clip's own audio become triggers. Arm to capture from a live input instead."
        case .midi:
            return model.isArmed
                ? "Listening for note-ons. Play the clip and hit pads to place triggers."
                : "Arm, then perform on a controller. Bind a rule to one note to give it its own pad."
        case .manual:
            return "Double-click the timeline to place triggers by hand."
        }
    }

    // MARK: Detection — coral, still the trigger path

    private var detectionPanel: some View {
        PanelFrame(title: "Detection", color: Sungam.coral) {
            VStack(alignment: .leading, spacing: 12) {
                Selector(options: OnsetBand.allCases.map { ($0, $0.shortName) },
                         selection: Binding(
                            get: { model.onsetSettings.band },
                            set: { model.onsetSettings.band = $0 }
                         ),
                         color: Sungam.coral)

                Text(model.onsetSettings.band.displayName)
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink38)

                HStack(spacing: 14) {
                    Knob(label: "Sensitivity",
                         value: Binding(
                            get: { model.onsetSettings.sensitivity },
                            set: { model.onsetSettings.sensitivity = $0 }
                         ),
                         radius: 20, color: Sungam.coral,
                         format: { String(format: "%.2f", $0) })

                    Knob(label: "Hold-off",
                         value: Binding(
                            get: { model.onsetSettings.holdOff },
                            set: { model.onsetSettings.holdOff = $0 }
                         ),
                         range: 0.02 ... 0.6, radius: 15, color: Sungam.coral,
                         format: { String(format: "%.0fms", $0 * 1000) })

                    Spacer()
                }

                if model.isArmed {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("INPUT")
                                .font(Sungam.mono(Sungam.text2xs))
                                .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                                .foregroundStyle(Sungam.ink62)
                            Lamp(on: hitRecently, color: Sungam.amber, size: 7)
                        }
                        SegmentMeter(level: min(1, model.audioInput.level * 2.2),
                                     color: Sungam.coral, segments: 14)
                            .frame(height: 8 * Sungam.scale)

                        if model.audioInput.permissionDenied {
                            Text("Microphone access denied. System Settings ▸ Privacy & Security ▸ Microphone.")
                                .font(Sungam.mono(Sungam.text2xs))
                                .foregroundStyle(Sungam.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var hitRecently: Bool {
        guard let t = model.audioInput.lastHitAt else { return false }
        return Date().timeIntervalSince(t) < 0.12
    }

    // MARK: MIDI — steel

    private var midiPanel: some View {
        PanelFrame(title: "MIDI", color: Sungam.steel) {
            VStack(alignment: .leading, spacing: 10) {
                Text("INPUT DEVICE")
                    .font(Sungam.mono(Sungam.text2xs))
                    .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.ink62)

                if model.midiInput.availableSources.isEmpty {
                    Text("No MIDI sources found. Connect a device and it appears here.")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(Sungam.ink38)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Every position stays labelled, so the device list reads
                    // top to bottom rather than hiding in a pop-up.
                    Selector(options: [(MIDIUniqueID?.none, "All devices")]
                                + model.midiInput.availableSources.map {
                                    (MIDIUniqueID?.some($0.id), $0.name)
                                },
                             selection: Binding(
                                get: { model.midiInput.selectedSourceID },
                                set: { model.midiInput.selectedSourceID = $0 }
                             ),
                             color: Sungam.steel,
                             vertical: true)
                }

                if let n = model.midiInput.lastNote {
                    LabelValue(label: "Last",
                               value: "\(n.number.midiNoteName)  \(n.number)  VEL \(n.velocity)  CH \(n.channel + 1)",
                               color: Sungam.steel, size: Sungam.textSm)
                } else if model.midiInput.isRunning {
                    Text("Waiting for a note.")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(Sungam.ink38)
                }

                if let e = model.midiInput.errorText {
                    Text(e).font(Sungam.mono(Sungam.text2xs)).foregroundStyle(Sungam.amber)
                }
            }
        }
    }

    // MARK: Effects — teal, the engine

    private var effectsPanel: some View {
        PanelFrame(title: "Effects", color: Sungam.teal) {
            VStack(alignment: .leading, spacing: 12) {
                // The whole palette sits above the rules it builds, so what is
                // available is visible without opening anything.
                Text("AVAILABLE")
                    .font(Sungam.mono(Sungam.text2xs))
                    .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.ink45)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4),
                          spacing: 5) {
                    ForEach(MoshOpKind.byFamily) { kind in
                        LatchButton(label: kind.displayName, color: kind.signalColor) {
                            model.rules.append(
                                MoshRule(kind: kind, source: model.triggerSource,
                                         band: model.triggerSource == .audio
                                               ? model.onsetSettings.band : nil)
                            )
                        }
                    }
                }

                HStack(spacing: 12) {
                    ForEach(["strips": Sungam.coral, "holds": Sungam.teal,
                             "reorders": Sungam.steel].sorted(by: { $0.key < $1.key }),
                            id: \.key) { name, color in
                        HStack(spacing: 5) {
                            Lamp(on: true, color: color, size: 6)
                            Text(name.uppercased())
                                .font(Sungam.mono(Sungam.text2xs))
                                .tracking(Sungam.text2xs * Sungam.scale * 0.06)
                                .foregroundStyle(Sungam.ink45)
                        }
                    }
                }

                Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)

                Text("IN USE")
                    .font(Sungam.mono(Sungam.text2xs))
                    .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.ink45)

                if model.rules.isEmpty {
                    Text("None. Add one above.")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(Sungam.ink38)
                } else {
                    Text("Drag across an effect's lane on the timeline to set where it is live. Double-click a span to remove it.")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink45)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach($model.rules) { $rule in
                    RuleRow(rule: $rule, lastNote: model.midiInput.lastNote?.number) {
                        model.rules.removeAll { $0.id == rule.id }
                    }
                }
            }
        }
    }

    // MARK: Stream — steel, the render chain

    private var streamPanel: some View {
        PanelFrame(title: "Stream", color: Sungam.steel) {
            VStack(alignment: .leading, spacing: 10) {
                Latch(label: "Strip every keyframe",
                      on: $model.moshSettings.purgeAllKeyframes, color: Sungam.steel)
                Text("The picture never resets — the whole clip becomes one continuous smear.")
                    .font(Sungam.mono(Sungam.textSm))
                    .foregroundStyle(Sungam.ink45)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Latch(label: "Protect first frame",
                      on: $model.moshSettings.protectFirstFrame, color: Sungam.steel)
                Text("Keeps the opening keyframe so the clip has something to start from.")
                    .font(Sungam.mono(Sungam.textSm))
                    .foregroundStyle(Sungam.ink45)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)

                LabelValue(label: "Encoder", value: model.ffmpegSummary,
                           color: model.ffmpegMissing ? Sungam.amber : Sungam.steel,
                           size: Sungam.textSm)
            }
        }
    }
}

/// One effect rule. Collapsed it reads as a lamp, a name and a duration; open
/// it exposes the knobs. Modulation parameters are violet, and only those.
struct RuleRow: View {
    @Binding var rule: MoshRule
    var lastNote: Int?
    var onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Lamp(on: rule.enabled, color: rule.kind.signalColor, size: 9)
                    .onTapGesture { rule.enabled.toggle() }

                Text(rule.kind.displayName.uppercased())
                    .font(Sungam.mono(Sungam.textBase, weight: .bold))
                    .tracking(Sungam.textBase * Sungam.scale * 0.06)
                    .foregroundStyle(rule.enabled ? Sungam.ink85 : Sungam.ink38)

                Text(rule.kind.summary)
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink38)
                    .lineLimit(1)

                Spacer()

                Text(rule.activeRegions.isEmpty
                     ? "ALWAYS"
                     : "\(rule.activeRegions.count) SPAN\(rule.activeRegions.count == 1 ? "" : "S")")
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(rule.activeRegions.isEmpty ? Sungam.ink38
                                                                : rule.kind.signalColor)

                Text(String(format: "%.0fMS", rule.duration * 1000))
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink62)

                LatchButton(label: expanded ? "Close" : "Edit") { expanded.toggle() }
                LatchButton(label: "Del", action: onDelete)
            }

            if expanded {
                if !rule.activeRegions.isEmpty {
                    HStack(spacing: 8) {
                        Text("Live only inside the painted spans.")
                            .font(Sungam.mono(Sungam.text2xs))
                            .foregroundStyle(Sungam.ink55)
                        Spacer()
                        LatchButton(label: "Always") { rule.activeRegions.removeAll() }
                    }
                }

                Text(rule.kind.blurb)
                    .font(Sungam.mono(Sungam.textSm))
                    .foregroundStyle(Sungam.ink70)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)

                Selector(options: TriggerSource.allCases.map { ($0, $0.displayName) },
                         selection: $rule.source, color: rule.kind.signalColor)

                if rule.source == .audio {
                    Selector(options: OnsetBand.allCases.map { ($0, $0.shortName) },
                             selection: Binding(
                                get: { rule.band ?? .full },
                                set: { rule.band = $0 }
                             ),
                             color: rule.kind.signalColor)
                }

                if rule.source == .midi {
                    HStack(spacing: 8) {
                        LabelValue(label: "Note",
                                   value: rule.note.map { "\($0.midiNoteName)" } ?? "ANY",
                                   color: Sungam.steel, size: Sungam.textSm)
                        Spacer()
                        LatchButton(label: "Learn", enabled: lastNote != nil) {
                            rule.note = lastNote
                        }
                        LatchButton(label: "Any") { rule.note = nil }
                    }
                }

                // The effect's own settings.
                HStack(spacing: 10) {
                    Knob(label: "Length", value: $rule.duration, range: 0.03 ... 3.0,
                         radius: 15, color: rule.kind.signalColor,
                         format: { String(format: "%.0fms", $0 * 1000) })
                    Knob(label: "Amount", value: $rule.amountFloor,
                         radius: 15, color: rule.kind.signalColor,
                         format: { String(format: "%.2f", $0) })
                    Spacer()
                }

                // Modulation — violet, and nothing else on the panel is violet.
                HStack(spacing: 10) {
                    Knob(label: "Velocity", value: $rule.strengthInfluence,
                         radius: 13, color: Sungam.violet,
                         format: { String(format: "%.2f", $0) })
                    Knob(label: "Chance", value: $rule.probability,
                         radius: 13, color: Sungam.violet,
                         format: { String(format: "%.2f", $0) })
                    Knob(label: "Jitter", value: $rule.durationJitter,
                         radius: 13, color: Sungam.violet,
                         format: { String(format: "%.2f", $0) })
                    Knob(label: "Offset", value: $rule.offset, range: -0.3 ... 0.3,
                         radius: 13, color: Sungam.violet, bipolar: true,
                         format: { String(format: "%+.0fms", $0 * 1000) })
                }
            }
        }
        .padding(10)
        .overlay(Rectangle().stroke(Sungam.ink13, lineWidth: Sungam.hairline))
    }
}

extension OnsetBand {
    /// The selector labels every position rather than abbreviating to fit, but
    /// the band names carry their instrument in a subcaption instead of inline.
    var shortName: String {
        switch self {
        case .full: return "Full"
        case .low: return "Low"
        case .mid: return "Mid"
        case .high: return "High"
        }
    }
}
