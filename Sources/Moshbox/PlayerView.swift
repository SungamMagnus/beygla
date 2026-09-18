import AVFoundation
import AppKit
import SwiftUI

/// AVPlayerLayer in a SwiftUI wrapper. Using the layer directly rather than
/// `VideoPlayer` keeps the transport under the model's control, which matters
/// because live triggers are timestamped against the playhead.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainer {
        let v = PlayerContainer()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ nsView: PlayerContainer, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    final class PlayerContainer: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
