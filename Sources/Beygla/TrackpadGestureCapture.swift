import AppKit
import SwiftUI

/// Wraps SwiftUI content in an NSView that also catches trackpad pinch and
/// two-finger scroll — gestures SwiftUI has no view-level modifier for on
/// macOS. The trick is where the overrides live: on the *wrapper*, not on
/// the view showing the content. Mouse clicks and drags hit-test to the
/// hosted content first (it is the frontmost view under the cursor) and are
/// handled there exactly as before; `magnify`/`scrollWheel` are not claimed
/// by anything SwiftUI puts in the hierarchy — no gesture recognizer here
/// hooks into those AppKit event methods — so they fall through the
/// responder chain to this wrapper untouched.
struct TrackpadGestureCapture<Content: View>: NSViewRepresentable {
    /// `factor` is the multiplicative zoom change for this event
    /// (`1 + event.magnification`); `xFraction` is where the gesture is
    /// centred, 0...1 across the view's width, so the moment under the
    /// cursor can stay under the cursor as the zoom changes.
    var onMagnify: (_ factor: Double, _ xFraction: Double) -> Void
    /// Horizontal scroll delta in points, positive is a swipe that should
    /// reveal content to the right (matches `NSEvent.scrollingDeltaX`).
    var onPanX: (_ deltaX: Double) -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onMagnify = onMagnify
        v.onPanX = onPanX
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: v.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        v.hostingView = hosting
        return v
    }

    func updateNSView(_ v: CaptureView, context: Context) {
        v.onMagnify = onMagnify
        v.onPanX = onPanX
        v.hostingView?.rootView = content()
    }

    final class CaptureView: NSView {
        var onMagnify: ((Double, Double) -> Void)?
        var onPanX: ((Double) -> Void)?
        var hostingView: NSHostingView<Content>?

        override func magnify(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            let fraction = bounds.width > 0 ? Double(local.x / bounds.width) : 0.5
            onMagnify?(1 + event.magnification, min(max(0, fraction), 1))
        }

        override func scrollWheel(with event: NSEvent) {
            // Only a horizontal component is meaningful here — the timeline
            // has nothing to scroll vertically — so a mostly-vertical swipe
            // (someone scrolling the window around the timeline) is left
            // alone rather than being misread as a pan.
            guard event.scrollingDeltaX != 0 else {
                super.scrollWheel(with: event)
                return
            }
            onPanX?(Double(event.scrollingDeltaX))
        }
    }
}
