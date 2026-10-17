import AppKit
import CoreMIDI
import MoshCore
import SwiftUI

/// The trigger source's own controls, in one strip between the transport and
/// the timeline — beside the waveform and ticks they decide, rather than in
/// the inspector with the effects they feed. The source itself is picked in
/// the header; this strip changes with it.
struct TriggerBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("TRIGGERS")
                .font(Sungam.mono(Sungam.text2xs, weight: .bold))
                .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                .foregroundStyle(Sungam.coral)
                .help(blurb)

            divider

            switch model.triggerSource {
            case .audio: audio
            case .midi: midi
            case .sync: sync
            case .manual: hint("Double-click the timeline to place triggers by hand.")
            }

            Spacer(minLength: 8)

            // Switching source does not move existing effects — each keeps
            // listening to what it was set to — so say so, and offer the
            // one-step way to move them.
            if model.triggerSource != .manual && model.effectsOnOtherSources > 0 {
                let n = model.effectsOnOtherSources
                Text("\(n) effect\(n == 1 ? "" : "s") elsewhere")
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink55)
                    .fixedSize()
                LatchButton(label: "Move here", color: Sungam.coral) {
                    model.moveAllEffects(to: model.triggerSource)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30 * Sungam.scale)
        .background(Sungam.ink(0.03))
        .overlay(Rectangle().stroke(Sungam.ink13, lineWidth: Sungam.hairline))
    }

    // MARK: Audio — detection, plus live capture

    private var audio: some View {
        HStack(spacing: 10) {
            Selector(options: OnsetBand.allCases.map { ($0, $0.shortName) },
                     selection: Binding(get: { model.onsetSettings.band },
                                        set: { model.onsetSettings.band = $0 }),
                     color: Sungam.coral)
                .frame(width: 190 * Sungam.scale / 1.25)
                .help(model.onsetSettings.band.displayName)

            NumBox(label: "Sens", value: Binding(get: { model.onsetSettings.sensitivity },
                                                 set: { model.onsetSettings.sensitivity = $0 }),
                   color: Sungam.coral, inline: true,
                   format: { String(format: "%.2f", $0) })

            NumBox(label: "Hold", value: Binding(get: { model.onsetSettings.holdOff },
                                                 set: { model.onsetSettings.holdOff = $0 }),
                   range: 0.02 ... 0.6, color: Sungam.coral, entryScale: 1000, inline: true,
                   format: { String(format: "%.0fms", $0 * 1000) })

            divider
            arm

            if model.isArmed {
                SegmentMeter(level: min(1, model.audioInput.level * 2.2),
                             color: Sungam.coral, segments: 10)
                    .frame(width: 90 * Sungam.scale / 1.25)
                if model.audioInput.permissionDenied {
                    Text("Mic access denied")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.amber)
                        .help("System Settings ▸ Privacy & Security ▸ Microphone")
                }
            }
        }
    }

    // MARK: MIDI — device, last note, live capture

    private var midi: some View {
        HStack(spacing: 10) {
            if model.midiInput.availableSources.isEmpty {
                hint("No MIDI devices — connect one and it appears here.")
            } else {
                let options: [(value: MIDIUniqueID?, label: String)] =
                    [(nil, "All devices")]
                    + model.midiInput.availableSources.map { (MIDIUniqueID?.some($0.id), $0.name) }
                let current = options.first { $0.value == model.midiInput.selectedSourceID }?.label
                    ?? "All devices"
                DropdownLatch(label: current, color: Sungam.steel, options: options,
                              selection: model.midiInput.selectedSourceID) {
                    model.midiInput.selectedSourceID = $0
                }
            }

            if let n = model.midiInput.lastNote {
                LabelValue(label: "Last",
                           value: "\(n.number.midiNoteName)  VEL \(n.velocity)  CH \(n.channel + 1)",
                           color: Sungam.steel, size: Sungam.text2xs)
            }
            if let e = model.midiInput.errorText {
                Text(e).font(Sungam.mono(Sungam.text2xs)).foregroundStyle(Sungam.amber)
                    .lineLimit(1)
            }

            divider
            arm
        }
    }

    // MARK: Sync — tempo grid

    private var bpm: Binding<Double> {
        Binding(get: { model.syncSettings.bpm },
                set: { v in
                    let r = SyncSettings.bpmRange
                    model.syncSettings.bpm = min(max(v, r.lowerBound), r.upperBound)
                })
    }

    private var sync: some View {
        HStack(spacing: 8) {
            // Drags snap to whole BPM; a typed value keeps its decimal.
            NumBox(label: "BPM", value: bpm, range: SyncSettings.bpmRange,
                   color: Sungam.teal, dragStep: 1, inline: true,
                   format: { $0 == $0.rounded() ? String(format: "%.0f", $0)
                                                : String(format: "%.2f", $0) })
            LatchButton(label: "Tap", color: Sungam.teal) { model.tapTempo() }

            DropdownLatch(label: model.syncSettings.noteValue.displayName, color: Sungam.teal,
                          options: NoteValue.allCases.map { ($0, $0.displayName) },
                          selection: model.syncSettings.noteValue) {
                model.syncSettings.noteValue = $0
            }

            divider

            LabelValue(label: "Beat 1", value: String(format: "%.2fs", model.syncSettings.offset),
                       color: Sungam.teal, size: Sungam.text2xs)
            LatchButton(label: "At playhead") { model.setDownbeatAtPlayhead() }
                .help("Put beat 1 where the playhead is")

            Latch(label: "Accent", on: $model.syncSettings.accentDownbeat,
                  color: Sungam.teal, width: 60)
                .help("Beat 1 of each bar fires at full strength and the rest at about half, so an effect's Velocity setting makes the downbeat hit hardest.")
        }
    }

    // MARK: Pieces

    private var arm: some View {
        HStack(spacing: 6) {
            Lamp(on: model.isArmed && hitRecently, color: Sungam.amber, size: 7)
            Latch(label: model.isArmed ? "Armed" : "Arm live", on: Binding(
                get: { model.isArmed }, set: { model.setArmed($0) }),
                  color: Sungam.amber, width: 70)
        }
        .help(blurb)
    }

    private var hitRecently: Bool {
        guard let t = model.audioInput.lastHitAt else { return model.isArmed }
        return Date().timeIntervalSince(t) < 0.12
    }

    private var divider: some View {
        Rectangle().fill(Sungam.ink18).frame(width: Sungam.hairline, height: 14)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Sungam.mono(Sungam.text2xs))
            .foregroundStyle(Sungam.ink45)
            .lineLimit(1)
    }

    private var blurb: String {
        switch model.triggerSource {
        case .audio:
            return model.isArmed
                ? "Listening to live input. Play the clip; every transient lands as a trigger at the playhead."
                : "Transients in the clip's own audio become triggers. Arm to capture from a live input instead."
        case .midi:
            return model.isArmed
                ? "Listening for note-ons. Play the clip and hit pads to place triggers."
                : "Arm, then perform on a controller. Bind a rule to one note to give it its own pad."
        case .sync:
            return "Triggers on a fixed tempo grid. Set the BPM and note length, then put beat 1 where the track's downbeat falls."
        case .manual:
            return "Double-click the timeline to place triggers by hand."
        }
    }
}
