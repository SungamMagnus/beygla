import Combine
import CoreMIDI
import Foundation

/// CoreMIDI note-on listener.
///
/// Every connected source is joined at once, so a controller plugged in while
/// the app is running still works without the user hunting for a device menu.
@MainActor
public final class MIDIInput: ObservableObject {
    public struct Note: Identifiable, Hashable {
        public var id = UUID()
        public var number: Int
        public var velocity: Int
        public var channel: Int
        public var receivedAt: Date
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var sourceNames: [String] = []
    @Published public private(set) var lastNote: Note?
    @Published public private(set) var errorText: String?

    /// Called on the main actor for every note-on with velocity > 0.
    public var onNote: ((Note) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    public init() {}

    public func start() {
        guard !isRunning else { return }

        var status = MIDIClientCreateWithBlock("Beygla" as CFString, &client) { [weak self] notification in
            // Devices coming and going: re-scan so a controller plugged in later
            // still ends up connected.
            let type = notification.pointee.messageID
            if type == .msgObjectAdded || type == .msgObjectRemoved {
                Task { @MainActor in self?.connectAllSources() }
            }
        }
        guard status == noErr else {
            errorText = "Could not open MIDI client (\(status))"
            return
        }

        status = MIDIInputPortCreateWithProtocol(
            client, "Beygla In" as CFString, ._1_0, &port
        ) { [weak self] eventList, _ in
            let notes = Self.parse(eventList)
            guard !notes.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                for n in notes {
                    self.lastNote = n
                    self.onNote?(n)
                }
            }
        }
        guard status == noErr else {
            errorText = "Could not open MIDI port (\(status))"
            return
        }

        isRunning = true
        errorText = nil
        connectAllSources()
    }

    public func stop() {
        guard isRunning else { return }
        MIDIPortDispose(port)
        MIDIClientDispose(client)
        isRunning = false
        sourceNames = []
    }

    private func connectAllSources() {
        var names: [String] = []
        for i in 0 ..< MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)
            var cf: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cf) == noErr,
               let name = cf?.takeRetainedValue() as String? {
                names.append(name)
            }
        }
        sourceNames = names
    }

    /// Pull note-ons out of a UMP event list.
    private nonisolated static func parse(_ list: UnsafePointer<MIDIEventList>) -> [Note] {
        var notes: [Note] = []
        var packet = list.pointee.packet

        for _ in 0 ..< list.pointee.numPackets {
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                let count = Int(packet.wordCount)
                var w = 0
                while w < count && w < words.count {
                    let word = words[w]
                    let messageType = UInt8((word >> 28) & 0xF)
                    // 0x2 = MIDI 1.0 channel voice, one word per message.
                    if messageType == 0x2 {
                        let statusNibble = UInt8((word >> 20) & 0xF)
                        let channel = Int((word >> 16) & 0xF)
                        let data1 = Int((word >> 8) & 0x7F)
                        let data2 = Int(word & 0x7F)
                        if statusNibble == 0x9 && data2 > 0 {
                            notes.append(Note(number: data1, velocity: data2,
                                              channel: channel, receivedAt: Date()))
                        }
                        w += 1
                    } else if messageType == 0x4 {
                        // MIDI 2.0 channel voice: two words, 16-bit velocity.
                        guard w + 1 < count else { break }
                        let statusNibble = UInt8((word >> 20) & 0xF)
                        let channel = Int((word >> 16) & 0xF)
                        let note = Int((word >> 8) & 0x7F)
                        let velocity16 = Int((words[w + 1] >> 16) & 0xFFFF)
                        if statusNibble == 0x9 && velocity16 > 0 {
                            notes.append(Note(number: note, velocity: velocity16 >> 9,
                                              channel: channel, receivedAt: Date()))
                        }
                        w += 2
                    } else {
                        // Utility / SysEx / data messages: skip by declared size.
                        w += messageType <= 0x2 ? 1 : (messageType <= 0x4 ? 2 : 4)
                    }
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
        return notes
    }
}

public extension Int {
    /// "C3", "F#4" — for showing a learned MIDI binding.
    var midiNoteName: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = self / 12 - 1
        return "\(names[self % 12])\(octave)"
    }
}
