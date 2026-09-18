import MoshCore
import SwiftUI

struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
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
                    .lineSpacing(2)
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
            VStack(alignment: .leading, spacing: 8) {
                if model.midiInput.isRunning {
                    if model.midiInput.sourceNames.isEmpty {
                        Text("No MIDI sources found.")
                            .font(Sungam.mono(Sungam.textSm))
                            .foregroundStyle(Sungam.ink38)
                    } else {
                        ForEach(model.midiInput.sourceNames, id: \.self) { name in
                            HStack(spacing: 6) {
                                Lamp(on: true, color: Sungam.steel, size: 6)
                                Text(name)
                                    .font(Sungam.mono(Sungam.textSm))
                                    .foregroundStyle(Sungam.ink85)
                            }
                        }
                    }
                    if let n = model.midiInput.lastNote {
                        LabelValue(label: "Last",
                                   value: "\(n.number.midiNoteName)  \(n.number)  VEL \(n.velocity)  CH \(n.channel + 1)",
                                   color: Sungam.steel, size: Sungam.textSm)
                    }
                } else {
                    Text("Arm live capture to connect MIDI devices.")
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
            VStack(alignment: .leading, spacing: 10) {
                if model.rules.isEmpty {
                    Text("No effects. Add one below.")
                        .font(Sungam.mono(Sungam.textSm))
                        .foregroundStyle(Sungam.ink38)
                }

                ForEach($model.rules) { $rule in
                    RuleRow(rule: $rule, lastNote: model.midiInput.lastNote?.number) {
                        model.rules.removeAll { $0.id == rule.id }
                    }
                }

                Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)

                Text("ADD")
                    .font(Sungam.mono(Sungam.text2xs))
                    .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                    .foregroundStyle(Sungam.ink45)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                          spacing: 6) {
                    ForEach(MoshOpKind.allCases) { kind in
                        LatchButton(label: kind.displayName, color: kind.signalColor) {
                            model.rules.append(
                                MoshRule(kind: kind, source: model.triggerSource,
                                         band: model.triggerSource == .audio
                                               ? model.onsetSettings.band : nil)
                            )
                        }
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
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink45)
                    .fixedSize(horizontal: false, vertical: true)

                Latch(label: "Protect first frame",
                      on: $model.moshSettings.protectFirstFrame, color: Sungam.steel)
                Text("Keeps the opening keyframe so the clip has something to start from.")
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink45)
                    .fixedSize(horizontal: false, vertical: true)
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

                Text(rule.kind.family)
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink38)

                Spacer()

                Text(String(format: "%.0fMS", rule.duration * 1000))
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink62)

                LatchButton(label: expanded ? "Close" : "Edit") { expanded.toggle() }
                LatchButton(label: "Del", action: onDelete)
            }

            if expanded {
                Text(rule.kind.blurb)
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink55)
                    .fixedSize(horizontal: false, vertical: true)

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
