import MoshCore
import SwiftUI

struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                triggerSourceBox
                if model.triggerSource == .audio { audioBox }
                if model.triggerSource == .midi { midiBox }
                rulesBox
                globalsBox
            }
            .padding(12)
        }
        .background(Theme.bg)
    }

    // MARK: Source

    private var triggerSourceBox: some View {
        SectionBox(title: "Trigger source") {
            Picker("", selection: $model.triggerSource) {
                ForEach(TriggerSource.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(sourceBlurb)
                .font(.caption2).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            if model.triggerSource != .manual {
                Button {
                    model.setArmed(!model.isArmed)
                } label: {
                    Label(model.isArmed ? "Disarm" : "Arm live capture",
                          systemImage: model.isArmed ? "stop.circle" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isArmed ? Theme.hot : Theme.panel)
                .controlSize(.small)
            }
        }
    }

    private var sourceBlurb: String {
        switch model.triggerSource {
        case .audio:
            return model.isArmed
                ? "Listening to live input. Play the clip and every transient lands as a trigger at the playhead."
                : "Transients in the clip's own audio become triggers. Arm to capture from a live input instead."
        case .midi:
            return model.isArmed
                ? "Listening for note-ons. Play the clip and hit pads to place triggers."
                : "Arm, then play the clip and perform on a controller. Bind a rule to one note to give it its own pad."
        case .manual:
            return "Double-click the timeline to place triggers by hand."
        }
    }

    // MARK: Audio

    private var audioBox: some View {
        SectionBox(title: "Audio detection") {
            Picker("Band", selection: Binding(
                get: { model.onsetSettings.band },
                set: { model.onsetSettings.band = $0 }
            )) {
                ForEach(OnsetBand.allCases) { Text($0.displayName).tag($0) }
            }
            .controlSize(.small)

            ParamSlider(title: "Sensitivity", value: Binding(
                get: { model.onsetSettings.sensitivity },
                set: { model.onsetSettings.sensitivity = $0 }
            ))

            ParamSlider(title: "Hold-off", value: Binding(
                get: { model.onsetSettings.holdOff },
                set: { model.onsetSettings.holdOff = $0 }
            ), range: 0.02 ... 0.6, format: { String(format: "%.0f ms", $0 * 1000) })

            if model.isArmed {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input level").font(.caption).foregroundStyle(Theme.dim)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(hitRecently ? Theme.hot : Theme.accent)
                                .frame(width: geo.size.width * min(1, model.audioInput.level * 2.2))
                        }
                    }
                    .frame(height: 6)
                    if model.audioInput.permissionDenied {
                        Text("Microphone access denied — enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                            .font(.caption2).foregroundStyle(Theme.hot)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var hitRecently: Bool {
        guard let t = model.audioInput.lastHitAt else { return false }
        return Date().timeIntervalSince(t) < 0.1
    }

    // MARK: MIDI

    private var midiBox: some View {
        SectionBox(title: "MIDI input") {
            if model.midiInput.isRunning {
                if model.midiInput.sourceNames.isEmpty {
                    Text("No MIDI sources found.").font(.caption).foregroundStyle(Theme.dim)
                } else {
                    ForEach(model.midiInput.sourceNames, id: \.self) { name in
                        Label(name, systemImage: "pianokeys")
                            .font(.caption).foregroundStyle(Theme.text)
                    }
                }
                if let n = model.midiInput.lastNote {
                    Text("Last: \(n.number.midiNoteName) (\(n.number)) vel \(n.velocity) ch \(n.channel + 1)")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                }
            } else {
                Text("Arm live capture to connect MIDI devices.")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            if let e = model.midiInput.errorText {
                Text(e).font(.caption2).foregroundStyle(Theme.hot)
            }
        }
    }

    // MARK: Rules

    private var rulesBox: some View {
        SectionBox(title: "Effects") {
            ForEach($model.rules) { $rule in
                RuleRow(rule: $rule, lastNote: model.midiInput.lastNote?.number) {
                    model.rules.removeAll { $0.id == rule.id }
                }
            }

            Menu {
                ForEach(MoshOpKind.allCases) { kind in
                    Button(kind.displayName) {
                        model.rules.append(MoshRule(kind: kind, source: model.triggerSource,
                                                    band: model.triggerSource == .audio
                                                          ? model.onsetSettings.band : nil))
                    }
                }
            } label: {
                Label("Add effect", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
        }
    }

    // MARK: Globals

    private var globalsBox: some View {
        SectionBox(title: "Stream") {
            Toggle("Strip every keyframe", isOn: $model.moshSettings.purgeAllKeyframes)
                .controlSize(.small).font(.caption)
            Text("The picture never resets — the whole clip becomes one continuous smear.")
                .font(.caption2).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Protect first frame", isOn: $model.moshSettings.protectFirstFrame)
                .controlSize(.small).font(.caption)
            Text("Keeps the opening keyframe so the clip has something to start from.")
                .font(.caption2).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RuleRow: View {
    @Binding var rule: MoshRule
    var lastNote: Int?
    var onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: $rule.enabled).labelsHidden().controlSize(.mini)

                Circle()
                    .fill(TimelineView().color(for: rule.kind))
                    .frame(width: 8, height: 8)

                Text(rule.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(rule.enabled ? Theme.text : Theme.dim)

                Spacer()

                Text(String(format: "%.0f ms", rule.duration * 1000))
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.dim)

                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)

                Button(action: onDelete) { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }

            if expanded {
                Text(rule.kind.blurb)
                    .font(.caption2).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Source", selection: $rule.source) {
                    ForEach(TriggerSource.allCases) { Text($0.displayName).tag($0) }
                }
                .controlSize(.mini).font(.caption2)

                if rule.source == .audio {
                    Picker("Band", selection: Binding(
                        get: { rule.band ?? .full },
                        set: { rule.band = $0 }
                    )) {
                        ForEach(OnsetBand.allCases) { Text($0.displayName).tag($0) }
                    }
                    .controlSize(.mini).font(.caption2)
                }

                if rule.source == .midi {
                    HStack {
                        Text(rule.note.map { "Note \($0.midiNoteName)" } ?? "Any note")
                            .font(.caption2).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Learn") { rule.note = lastNote }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(lastNote == nil)
                        Button("Any") { rule.note = nil }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                }

                ParamSlider(title: "Duration", value: $rule.duration,
                            range: 0.03 ... 3.0,
                            format: { String(format: "%.0f ms", $0 * 1000) })
                ParamSlider(title: "Amount floor", value: $rule.amountFloor)
                ParamSlider(title: "Velocity influence", value: $rule.strengthInfluence)
                ParamSlider(title: "Probability", value: $rule.probability)
                ParamSlider(title: "Length jitter", value: $rule.durationJitter)
                ParamSlider(title: "Offset", value: $rule.offset, range: -0.3 ... 0.3,
                            format: { String(format: "%+.0f ms", $0 * 1000) })
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }
}
