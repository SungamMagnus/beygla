import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MoshboxApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Moshbox", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear(perform: openLaunchArgument)
        }
        .defaultSize(width: 1240, height: 820)
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

    /// `Moshbox --open <path>` loads a clip straight away. Handy for iterating
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

enum Theme {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.45)
    static let accent = Color(red: 0.98, green: 0.85, blue: 0.10)   // trigger yellow
    static let hot = Color(red: 1.00, green: 0.30, blue: 0.35)      // live / armed
    static let wave = Color(red: 0.35, green: 0.85, blue: 0.95)
}

/// A labelled slider row, used all over the inspector.
struct ParamSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0 ... 1
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
            }
            Slider(value: $value, in: range).controlSize(.small).tint(Theme.accent)
        }
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.dim)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
    }
}
