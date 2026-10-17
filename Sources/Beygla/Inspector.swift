import AppKit
import MoshCore
import SwiftUI
import UniformTypeIdentifiers

struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Triggers live under the picture with the timeline they
                // draw on; this column is what happens to the frames.
                streamPanel
                effectsPanel
                vectorEffectsPanel
            }
            .padding(16)
        }
        .background(Sungam.paper)
    }

    // MARK: Effects — teal, the engine

    private var effectsPanel: some View {
        PanelFrame(title: "Effects", color: Sungam.teal) {
            VStack(alignment: .leading, spacing: 6) {
                // The whole palette sits above the rules it builds, so what is
                // available is visible without opening anything. One block per
                // family, each captioned with what the family does, on one
                // shared four-column grid so every chip lines up.
                ForEach(EffectFamily.all, id: \.name) { family in
                    EffectFamilyBlock(name: family.name, caption: family.caption,
                                      color: family.color,
                                      items: paletteItems(family.kinds)) { kind in
                        model.rules.append(
                            MoshRule(kind: kind, source: model.triggerSource,
                                     band: model.triggerSource == .audio
                                           ? model.onsetSettings.band : nil)
                        )
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
                }

                ForEach(Array($model.rules.enumerated()), id: \.element.id) { i, $rule in
                    let id = rule.id
                    RuleRow(rule: $rule, lastNote: model.midiInput.lastNote?.number,
                            position: i + 1,
                            onMoveUp: i > 0 ? { model.moveRule(id, by: -1) } : nil,
                            onMoveDown: i < model.rules.count - 1 ? { model.moveRule(id, by: 1) } : nil) {
                        model.rules.removeAll { $0.id == id }
                    }
                }
            }
        }
    }

    private func paletteItems(_ kinds: [MoshOpKind])
        -> [(label: String, help: String, uses: Int, id: MoshOpKind)] {
        kinds.map { k in
            (label: k.displayName, help: k.summary,
             uses: model.rules.filter { $0.kind == k }.count, id: k)
        }
    }

    private var vectorPaletteItems: [(label: String, help: String, uses: Int, id: VectorOpKind)] {
        VectorOpKind.allCases.map { k in
            (label: k.displayName, help: k.summary,
             uses: model.vectorRules.filter { $0.kind == k }.count, id: k)
        }
    }

    // MARK: Vector effects — lilac, subordinate to the bitstream engine
    //
    // A second, optional pass: motion vectors rewritten inside frames rather
    // than whole frames reordered. Needs ffgac/ffedit, a separate download
    // this app can run entirely without, so the panel says so plainly rather
    // than presenting broken controls when the tool is missing.

    private var vectorEffectsPanel: some View {
        PanelFrame(title: "Vector effects", color: Sungam.lilacText) {
            VStack(alignment: .leading, spacing: 6) {

                if model.vectorEngineMissing {
                    HStack(spacing: 6) {
                        Lamp(on: false, color: Sungam.amber, size: 7)
                        Text("ffgac/ffedit not found — run tools/build-ffglitch.sh")
                            .font(Sungam.mono(Sungam.text2xs))
                            .foregroundStyle(Sungam.amber)
                    }
                } else {
                    EffectFamilyBlock(name: "Motion",
                                      caption: "Bends motion inside frames rather than reordering them.",
                                      color: Sungam.lilacText,
                                      items: vectorPaletteItems) { kind in
                        model.vectorRules.append(
                            VectorRule(kind: kind, source: model.triggerSource,
                                      band: model.triggerSource == .audio
                                            ? model.onsetSettings.band : nil)
                        )
                    }

                    HStack(spacing: 8) {
                        Text("ORDER")
                            .font(Sungam.mono(Sungam.text2xs))
                            .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                            .foregroundStyle(Sungam.ink45)
                        Selector(options: [(true, "Vectors first"), (false, "Frames first")],
                                 selection: $model.vectorsFirst, color: Sungam.lilacText)
                    }
                    .help(model.vectorsFirst
                          ? "Vector effects bend the clean picture's motion, then the frame effects rework the result."
                          : "Frame effects mosh first and are baked into the picture, then the vector effects push that around.")

                    if !model.vectorRules.isEmpty {
                        Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)
                        Text("IN USE")
                            .font(Sungam.mono(Sungam.text2xs))
                            .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                            .foregroundStyle(Sungam.ink45)

                        ForEach(Array($model.vectorRules.enumerated()), id: \.element.id) { i, $rule in
                            let id = rule.id
                            VectorRuleRow(rule: $rule, lastNote: model.midiInput.lastNote?.number,
                                          position: i + 1,
                                          onMoveUp: i > 0 ? { model.moveVectorRule(id, by: -1) } : nil,
                                          onMoveDown: i < model.vectorRules.count - 1
                                            ? { model.moveVectorRule(id, by: 1) } : nil) {
                                model.vectorRules.removeAll { $0.id == id }
                            }
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
                Text(model.moshSettings.purgeAllKeyframes && model.smear != nil
                     ? "One continuous smear. Overrides Smear while on."
                     : "One continuous smear — the picture never resets.")
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink45)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Latch(label: "Protect first frame",
                      on: $model.moshSettings.protectFirstFrame, color: Sungam.steel)
                Text("Keeps the opening keyframe as a starting picture.")
                    .font(Sungam.mono(Sungam.text2xs))
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
/// it exposes the number boxes. Modulation parameters are violet, and only those.
struct RuleRow: View {
    @EnvironmentObject var model: AppModel
    @Binding var rule: MoshRule
    var lastNote: Int?
    var position: Int = 0
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onDelete: () -> Void
    @State private var expanded = false

    /// Jitter varies span length, which every effect but Bloom acts on
    /// directly; for Bloom it depends on Smear and trigger spacing.
    private var jitterMatters: Bool {
        rule.kind != .bloom || model.bloomLengthMatters(rule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Chain position: effects process the frames in this order.
                Text("\(position)")
                    .font(Sungam.mono(Sungam.text2xs, weight: .bold).monospacedDigit())
                    .foregroundStyle(Sungam.ink38)
                    .frame(width: 12 * Sungam.scale, alignment: .trailing)
                Lamp(on: rule.enabled, color: rule.kind.signalColor, size: 9)
                    .onTapGesture { rule.enabled.toggle() }

                Text(rule.kind.displayName.uppercased())
                    .font(Sungam.mono(Sungam.textBase, weight: .bold))
                    .tracking(Sungam.textBase * Sungam.scale * 0.06)
                    .foregroundStyle(rule.enabled ? Sungam.ink85 : Sungam.ink38)
                    .lineLimit(1)
                    .fixedSize()

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

                LatchButton(label: expanded ? "Done" : "Edit") { expanded.toggle() }
                LatchButton(label: "×", action: onDelete)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { expanded.toggle() }

            if expanded {
                HStack(spacing: 6) {
                    Text(rule.kind.summary)
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink45)
                        .lineLimit(1)
                    Spacer()
                    LatchButton(label: "↑ Earlier", enabled: onMoveUp != nil) { onMoveUp?() }
                    LatchButton(label: "↓ Later", enabled: onMoveDown != nil) { onMoveDown?() }
                }
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
                HStack(spacing: 8) {
                    NumBox(label: "Length", value: $rule.duration, range: 0.03 ... 3.0,
                           color: rule.kind.signalColor, entryScale: 1000,
                           format: { String(format: "%.0fms", $0 * 1000) })
                    NumBox(label: "Amount", value: $rule.amountFloor,
                           color: rule.kind.signalColor,
                           format: { String(format: "%.2f", $0) })
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }

                if !jitterMatters {
                    Text("Length and Jitter don't change a Bloom here: it strips its own keyframe whatever its length. They start to matter once Smear is set, or when a span reaches the next trigger.")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink45)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Modulation — violet, and nothing else on the panel is violet.
                HStack(spacing: 8) {
                    NumBox(label: "Velocity", value: $rule.strengthInfluence,
                           color: Sungam.violet,
                           format: { String(format: "%.2f", $0) })
                    NumBox(label: "Chance", value: $rule.probability,
                           color: Sungam.violet,
                           format: { String(format: "%.2f", $0) })
                    if jitterMatters {
                        NumBox(label: "Jitter", value: $rule.durationJitter,
                               color: Sungam.violet,
                               format: { String(format: "%.2f", $0) })
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                    NumBox(label: "Offset", value: $rule.offset, range: -0.3 ... 0.3,
                           color: Sungam.violet, bipolar: true, entryScale: 1000,
                           format: { String(format: "%+.0fms", $0 * 1000) })
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Sungam.ink(0.03))
        .overlay(Rectangle().stroke(Sungam.ink13, lineWidth: Sungam.hairline))
    }
}

/// The vector family's twin of `RuleRow` — same layout, same behaviour,
/// against `VectorRule`/`VectorOpKind` instead. Kept as a full duplicate
/// rather than a generic over both types: the two engines are different
/// enough (one edits a picture's motion, the other reorders whole frames)
/// that collapsing them into one generic would obscure more than it saves.
struct VectorRuleRow: View {
    @Binding var rule: VectorRule
    var lastNote: Int?
    var position: Int = 0
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Chain position: effects process the frames in this order.
                Text("\(position)")
                    .font(Sungam.mono(Sungam.text2xs, weight: .bold).monospacedDigit())
                    .foregroundStyle(Sungam.ink38)
                    .frame(width: 12 * Sungam.scale, alignment: .trailing)
                Lamp(on: rule.enabled, color: rule.kind.signalColor, size: 9)
                    .onTapGesture { rule.enabled.toggle() }

                Text(rule.kind.displayName.uppercased())
                    .font(Sungam.mono(Sungam.textBase, weight: .bold))
                    .tracking(Sungam.textBase * Sungam.scale * 0.06)
                    .foregroundStyle(rule.enabled ? Sungam.ink85 : Sungam.ink38)
                    .lineLimit(1)
                    .fixedSize()

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

                LatchButton(label: expanded ? "Done" : "Edit") { expanded.toggle() }
                LatchButton(label: "×", action: onDelete)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { expanded.toggle() }

            if expanded {
                HStack(spacing: 6) {
                    Text(rule.kind.summary)
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink45)
                        .lineLimit(1)
                    Spacer()
                    LatchButton(label: "↑ Earlier", enabled: onMoveUp != nil) { onMoveUp?() }
                    LatchButton(label: "↓ Later", enabled: onMoveDown != nil) { onMoveDown?() }
                }
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

                Text("Ported from \(rule.kind.source)")
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink38)

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

                HStack(spacing: 8) {
                    NumBox(label: "Length", value: $rule.duration, range: 0.03 ... 3.0,
                           color: rule.kind.signalColor, entryScale: 1000,
                           format: { String(format: "%.0fms", $0 * 1000) })
                    NumBox(label: "Amount", value: $rule.amountFloor,
                           color: rule.kind.signalColor,
                           format: { String(format: "%.2f", $0) })
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }

                HStack(spacing: 8) {
                    NumBox(label: "Velocity", value: $rule.strengthInfluence,
                           color: Sungam.violet,
                           format: { String(format: "%.2f", $0) })
                    NumBox(label: "Chance", value: $rule.probability,
                           color: Sungam.violet,
                           format: { String(format: "%.2f", $0) })
                    NumBox(label: "Jitter", value: $rule.durationJitter,
                           color: Sungam.violet,
                           format: { String(format: "%.2f", $0) })
                    NumBox(label: "Offset", value: $rule.offset, range: -0.3 ... 0.3,
                           color: Sungam.violet, bipolar: true, entryScale: 1000,
                           format: { String(format: "%+.0fms", $0 * 1000) })
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Sungam.ink(0.03))
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

// MARK: - Effect palette

/// The three bitstream families, in chain-colour order, each with the one line
/// that says what its members have in common.
struct EffectFamily {
    let name: String
    let caption: String
    let color: Color
    let kinds: [MoshOpKind]

    static let all: [EffectFamily] = ["strips", "holds", "reorders"].map { f in
        let kinds = MoshOpKind.byFamily.filter { $0.family == f }
        let caption = ["strips": "destroy keyframes",
                       "holds": "repeat what is there",
                       "reorders": "change the frame order"][f] ?? ""
        return EffectFamily(name: f, caption: caption,
                            color: kinds.first?.signalColor ?? Sungam.ink62, kinds: kinds)
    }
}

/// One family of add-effect chips: the family named in a narrow left column,
/// its members five across beside it. Every chip is the same width, so the
/// families stacked one above another line up column for column. The
/// family's one-line description is its tooltip.
struct EffectFamilyBlock<ID: Hashable>: View {
    let name: String
    let caption: String
    let color: Color
    var columns: Int = 5
    let items: [(label: String, help: String, uses: Int, id: ID)]
    let add: (ID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            HStack(spacing: 5) {
                Rectangle().fill(color).frame(width: 5 * Sungam.scale, height: 5 * Sungam.scale)
                Text(name.uppercased())
                    .font(Sungam.mono(Sungam.text2xs, weight: .bold))
                    .tracking(Sungam.text2xs * Sungam.scale * 0.04)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 58 * Sungam.scale / 1.25, height: 18 * Sungam.scale, alignment: .leading)
            .help(caption)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns),
                      alignment: .leading, spacing: 3) {
                ForEach(items, id: \.id) { item in
                    EffectChip(label: item.label, help: item.help, uses: item.uses,
                               color: color) { add(item.id) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One effect to add: a full-width cell with its family colour as an edge,
/// brightening under the pointer. A small lit corner marks an effect already
/// in the chain, so the palette doubles as a summary of what is in use.
struct EffectChip: View {
    let label: String
    let help: String
    var uses: Int = 0
    let color: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 2)
            Text(label.uppercased())
                .font(Sungam.mono(Sungam.text2xs))
                .foregroundStyle(hover ? Sungam.ink : Sungam.ink85)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.leading, 5)
                .padding(.trailing, 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18 * Sungam.scale)
        .overlay(alignment: .topTrailing) {
            if uses > 0 {
                Rectangle().fill(color)
                    .frame(width: 4 * Sungam.scale, height: 4 * Sungam.scale)
                    .padding(3)
            }
        }
        .background(hover ? color.opacity(0.16) : Sungam.ink(0.045))
        .overlay(Rectangle().stroke(hover ? color.opacity(0.6) : Sungam.ink13,
                                    lineWidth: Sungam.hairline))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .help(help)
    }
}
