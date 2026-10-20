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
                        model.removeTriggers(for: id)
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
                                model.removeTriggers(for: id)
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
                // Which engine's pass runs first. Steel, the render chain:
                // this is about the order the passes run in, not about
                // either family of effect.
                if !model.vectorEngineMissing {
                    HStack(spacing: 8) {
                        Text("ORDER")
                            .font(Sungam.mono(Sungam.text2xs))
                            .tracking(Sungam.text2xs * Sungam.scale * 0.08)
                            .foregroundStyle(Sungam.ink45)
                        Selector(options: [(false, "Effects first"), (true, "Vectors first")],
                                 selection: $model.vectorsFirst, color: Sungam.steel)
                    }
                    Text(model.vectorsFirst
                         ? "Vector effects bend the clean motion, then the effects cut up the result."
                         : "Effects mosh first, then vector effects push the moshed picture around.")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(Sungam.ink45)
                        .fixedSize(horizontal: false, vertical: true)

                    Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)
                }

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

                if rule.resetAfter {
                    Text("RESETS")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(rule.kind.signalColor)
                }

                Text(String(format: "%.0fMS", rule.duration * 1000))
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink62)

                LatchButton(label: expanded ? "Done" : "Edit") { expanded.toggle() }
                LatchButton(label: "×", action: onDelete)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { expanded.toggle() }

            // Open, top to bottom: what it does (the numbers), when it fires
            // (the trigger), and what it is (the note).
            if expanded {
                // The effect's own settings.
                HStack(spacing: 8) {
                    NumBox(label: "Length", value: $rule.duration, range: 0.03 ... 3.0,
                           color: rule.kind.signalColor, entryScale: 1000,
                           format: { String(format: "%.0fms", $0 * 1000) })
                    // Hidden where the effect has no "more" to give, rather
                    // than left as a control that does nothing.
                    if rule.kind.usesAmount {
                        NumBox(label: "Amount", value: $rule.amountFloor,
                               color: rule.kind.signalColor,
                               format: { String(format: "%.2f", $0) })
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    // Only where something is random: the effect itself, or
                    // Chance and Jitter rolling for it.
                    if rule.kind.isRandom || rule.probability < 1 || rule.durationJitter > 0 {
                        SeedBox(seed: $rule.seed, color: rule.kind.signalColor)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }

                // Modulation — violet, and nothing else on the panel is violet.
                HStack(spacing: 8) {
                    // Velocity only ever scales Amount.
                    if rule.kind.usesAmount {
                        NumBox(label: "Velocity", value: $rule.strengthInfluence,
                               color: Sungam.violet,
                               format: { String(format: "%.2f", $0) })
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
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

                RuleTriggerSection(source: $rule.source, band: $rule.band, note: $rule.note,
                                   resetAfter: $rule.resetAfter,
                                   lastNote: lastNote, color: rule.kind.signalColor,
                                   onMoveUp: onMoveUp, onMoveDown: onMoveDown)

                RuleInfo(text: rule.kind.blurb,
                         aside: jitterMatters ? nil
                             : "Length and Jitter only change a Bloom once Smear is set or a span reaches the next trigger.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Sungam.ink(0.03))
        .overlay(Rectangle().stroke(Sungam.ink13, lineWidth: Sungam.hairline))
    }
}

/// The middle of an open effect: which source it listens to, the band or
/// note within that source, whether it resets the picture when each span
/// ends, and where it sits in the chain. Shared by both kinds of effect row.
struct RuleTriggerSection: View {
    @Binding var source: TriggerSource
    @Binding var band: OnsetBand?
    @Binding var note: Int?
    @Binding var resetAfter: Bool
    var lastNote: Int?
    var color: Color
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)

            Selector(options: TriggerSource.allCases.map { ($0, $0.displayName) },
                     selection: $source, color: color)

            if source == .audio {
                Selector(options: OnsetBand.allCases.map { ($0, $0.shortName) },
                         selection: Binding(get: { band ?? .full }, set: { band = $0 }),
                         color: color)
            }

            HStack(spacing: 6) {
                if source == .midi {
                    LabelValue(label: "Note", value: note.map { "\($0.midiNoteName)" } ?? "ANY",
                               color: Sungam.steel, size: Sungam.text2xs)
                    LatchButton(label: "Learn", enabled: lastNote != nil) { note = lastNote }
                    LatchButton(label: "Any") { note = nil }
                }
                // A clean keyframe right where each span ends: the effect
                // stops cleanly instead of smearing on until something else
                // repaints the picture.
                Latch(label: "Reset after", on: $resetAfter, color: color, width: 84)
                    .help("Snap back to the clean picture the moment each of this effect's spans ends")
                Spacer()
                LatchButton(label: "↑ Earlier", enabled: onMoveUp != nil) { onMoveUp?() }
                LatchButton(label: "↓ Later", enabled: onMoveDown != nil) { onMoveDown?() }
            }
        }
    }
}

/// The foot of an open effect: what it does, in a sentence or two, set quiet
/// under a hairline so it reads as reference rather than as a control.
struct RuleInfo: View {
    let text: String
    var aside: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Sungam.ink13).frame(height: Sungam.hairline)
            Text(text)
                .font(Sungam.mono(Sungam.text2xs))
                .foregroundStyle(Sungam.ink55)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let aside {
                Text(aside)
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink38)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }
}

/// The vector family's twin of `RuleRow` — same layout, same behaviour,
/// against `VectorRule`/`VectorOpKind` instead. Kept as a full duplicate
/// rather than a generic over both types: the two engines are different
/// enough (one edits a picture's motion, the other reorders whole frames)
/// that collapsing them into one generic would obscure more than it saves.
struct VectorRuleRow: View {
    @EnvironmentObject var model: AppModel
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

                if rule.resetAfter {
                    Text("RESETS")
                        .font(Sungam.mono(Sungam.text2xs))
                        .foregroundStyle(rule.kind.signalColor)
                }

                Text(String(format: "%.0fMS", rule.duration * 1000))
                    .font(Sungam.mono(Sungam.text2xs))
                    .foregroundStyle(Sungam.ink62)

                LatchButton(label: expanded ? "Done" : "Edit") { expanded.toggle() }
                LatchButton(label: "×", action: onDelete)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { expanded.toggle() }

            // Same order as a frame effect: numbers, trigger, note.
            if expanded {
                HStack(spacing: 8) {
                    NumBox(label: "Length", value: $rule.duration, range: 0.03 ... 3.0,
                           color: rule.kind.signalColor, entryScale: 1000,
                           format: { String(format: "%.0fms", $0 * 1000) })
                    // Hidden where the effect has no "more" to give, rather
                    // than left as a control that does nothing.
                    if rule.kind.usesAmount {
                        NumBox(label: "Amount", value: $rule.amountFloor,
                               color: rule.kind.signalColor, bipolar: rule.kind.isBipolar,
                               format: { String(format: "%.2f", $0) })
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                    // Decay fades Amount across the span; for the effects with
                    // no Amount there is nothing to fade.
                    if rule.kind.usesAmount {
                        NumBox(label: "Decay", value: $rule.decay,
                               color: rule.kind.signalColor,
                               format: { String(format: "%.2f", $0) })
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                    if rule.kind.isRandom || rule.probability < 1 || rule.durationJitter > 0 {
                        SeedBox(seed: $rule.seed, color: rule.kind.signalColor)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }

                VectorExtras(rule: $rule)

                HStack(spacing: 8) {
                    // Velocity only ever scales Amount.
                    if rule.kind.usesAmount {
                        NumBox(label: "Velocity", value: $rule.strengthInfluence,
                               color: Sungam.violet,
                               format: { String(format: "%.2f", $0) })
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
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

                RuleTriggerSection(source: $rule.source, band: $rule.band, note: $rule.note,
                                   resetAfter: $rule.resetAfter,
                                   lastNote: lastNote, color: rule.kind.signalColor,
                                   onMoveUp: onMoveUp, onMoveDown: onMoveDown)

                RuleInfo(text: rule.kind.blurb, aside: "Ported from \(rule.kind.source)")
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

// MARK: - Seed

/// An effect's seed, boxed like a NumBox so it sits in the same row. A click
/// rolls a new one: the same settings, a different variation.
struct SeedBox: View {
    @Binding var seed: UInt32
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("SEED")
                .font(Sungam.mono(Sungam.text2xs))
                .tracking(Sungam.text2xs * Sungam.scale * 0.06)
                .foregroundStyle(Sungam.ink55)
            Text(verbatim: "\(seed)  ↻")
                .font(Sungam.mono(Sungam.textBase, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 19 * Sungam.scale)
                .background(Sungam.ink(0.04))
                .overlay(Rectangle().stroke(Sungam.ink22, lineWidth: Sungam.hairline))
                .contentShape(Rectangle())
                .onTapGesture { seed = UInt32.random(in: 1 ... 9999) }
                .help("Click for a new variation")
        }
        .frame(minWidth: 54 * Sungam.scale, maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Vector effect settings

/// The settings one vector effect has beyond Amount and Decay: an axis for
/// Mirror and Vibrate, a direction for Shift, a centre for the radial three,
/// Feedback for Delay, Threshold for Noise. Nothing for the rest.
struct VectorExtras: View {
    @EnvironmentObject var model: AppModel
    @Binding var rule: VectorRule

    var body: some View {
        let color = rule.kind.signalColor
        switch rule.kind {
        case .mirror:
            labelled("Axis") {
                Selector(options: [(MotionAxis.horizontal, "Left–right"), (.vertical, "Top–bottom"),
                                   (.both, "Both")],
                         selection: $rule.axis, color: color)
            }
        case .vibrate:
            labelled("Axis") {
                Selector(options: [(MotionAxis.both, "Both"), (.horizontal, "Across"),
                                   (.vertical, "Up–down")],
                         selection: $rule.axis, color: color)
            }
        case .shift:
            labelled("Direction") {
                Selector(options: MotionDirection.allCases.map { ($0, $0.rawValue.capitalized) },
                         selection: $rule.direction, color: color)
            }
        case .zoom, .slamZoom, .shear:
            HStack(alignment: .bottom, spacing: 8) {
                NumBox(label: "Centre X", value: $rule.centreX, color: color,
                       format: { String(format: "%.0f%%", $0 * 100) })
                NumBox(label: "Centre Y", value: $rule.centreY, color: color,
                       format: { String(format: "%.0f%%", $0 * 100) })
                let picking = model.centrePickRule == rule.id
                LatchButton(label: picking ? "Picking" : "Pick", color: color,
                            filled: picking) {
                    model.centrePickRule = picking ? nil : rule.id
                }
                .help("Click a point on the picture to pull from there")
                LatchButton(label: "Middle",
                            enabled: rule.centreX != 0.5 || rule.centreY != 0.5) {
                    rule.centreX = 0.5; rule.centreY = 0.5
                }
            }
        case .delay:
            HStack(spacing: 8) {
                NumBox(label: "Feedback", value: $rule.feedback, color: color,
                       format: { String(format: "%.2f", $0) })
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        case .noise:
            HStack(spacing: 8) {
                NumBox(label: "Threshold", value: $rule.threshold, range: 0.05 ... 1, color: color,
                       format: { String(format: "%.2f", $0) })
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        default:
            EmptyView()
        }
    }

    private func labelled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Sungam.mono(Sungam.text2xs))
                .tracking(Sungam.text2xs * Sungam.scale * 0.06)
                .foregroundStyle(Sungam.ink55)
            content()
        }
    }
}
