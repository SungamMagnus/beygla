import AppKit
import MoshCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct BeyglaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Beygla", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 700)
                .preferredColorScheme(.light)
                .onAppear(perform: openLaunchArgument)
        }
        .defaultSize(width: 1420, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { openVideo() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button(model.isArmed ? "Disarm" : "Arm Live Triggers") {
                    model.setArmed(!model.isArmed)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Clear Triggers") { model.clearTriggers() }
                    .keyboardShortcut(.delete, modifiers: [.command])
            }
        }
    }

    /// `Beygla --open <path>` loads a clip straight away. Handy for iterating
    /// on the UI without clicking through the open panel every time.
    private func openLaunchArgument() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return }
        model.load(url: URL(fileURLWithPath: args[i + 1]))
    }

    private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.load(url: url)
        }
    }
}

// MARK: - Effect colour assignment
//
// Colour is signal. The seven effects fall into three families by what they do
// to the frame array, and each family takes one hue — rather than seven hues
// chosen so the timeline looks busy.

extension MoshOpKind {
    var signalColor: Color {
        switch self {
        // Destroys reference frames: the primary transform.
        case .bloom, .void: return Sungam.coral
        // Repeats or holds what is already there.
        case .glide, .echo, .stutter, .freeze, .overlap: return Sungam.teal
        // Changes which frames are used, and in what order.
        case .reverse, .shuffle, .invert, .weave, .jiggle, .sort, .rise, .blockShuffle:
            return Sungam.steel
        }
    }

    /// Grouped by family so the palette reads as three colours, not fifteen.
    static var byFamily: [MoshOpKind] {
        [.bloom, .void,
         .glide, .echo, .stutter, .freeze, .overlap,
         .reverse, .invert, .weave, .jiggle, .sort, .rise, .shuffle, .blockShuffle]
    }

    var family: String {
        switch self {
        case .bloom, .void: return "strips"
        case .glide, .echo, .stutter, .freeze, .overlap: return "holds"
        case .reverse, .shuffle, .invert, .weave, .jiggle, .sort, .rise, .blockShuffle:
            return "reorders"
        }
    }
}
