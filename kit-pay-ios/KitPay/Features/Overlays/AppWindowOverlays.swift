import UIKit

/// A window that only claims the touches landing on the surface it is drawing.
///
/// Floating surfaces — the minimized call bubble, the voice-note bar — live above the app's own
/// window so sheets and full-screen covers cannot bury them. Everything outside the surface's own
/// frame must still reach the interface underneath, which is what the hit test below arranges.
final class OverlayPassthroughWindow: UIWindow {
    /// Set from the main actor; read on the main thread during hit testing.
    var interactiveFrameProvider: (() -> CGRect)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let frame = interactiveFrameProvider?(), frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// A plain reference box for the frame a floating surface currently occupies. Deliberately not
/// `@Published`: the surface reports its frame during layout, and publishing it would re-enter the
/// SwiftUI update it was measured in.
@MainActor
final class OverlayHitRegion {
    var frame: CGRect = .zero
}

/// Arbitrates the top-edge strip reservation in the app's own window.
///
/// A strip must PUSH the app below it — including UIKit navigation bars, which a SwiftUI
/// `safeAreaInset` cannot move (the bar pins to the hosting controller's safe area, so it stays
/// hidden underneath). Extending the app window's own safe area is the one mechanism every bar,
/// scroll view, and tab respects.
///
/// More than one overlay window can want that space (a minimized call, a voice note playing on
/// after its chat was left), and each owns a different window, so the reservation is registered by
/// key here instead of written directly: the tallest live claim wins, and releasing one surface can
/// never clear another's space.
@MainActor
enum AppWindowTopStripReservation {
    static let callKey = "call"
    static let voiceNoteKey = "voice-note"

    /// Breathing space between a strip and whatever the app draws under it.
    ///
    /// A strip claims only its own content height, and reserving exactly that put the screen's
    /// first row — a navigation title, the top of a thread — hard against the strip's bottom edge,
    /// reading as one squeezed block rather than two surfaces. The gap is added once, here, so the
    /// call strip and the voice-note bar are spaced identically and neither has to remember to.
    static let contentGap: CGFloat = 10

    private static var claims: [String: CGFloat] = [:]

    /// Registers (`height > 0`) or releases (`height <= 0`) one surface's claim.
    static func set(_ height: CGFloat, for key: String, in scene: UIWindowScene?) {
        if height > 0 {
            guard claims[key] != height else { return }
            claims[key] = height
        } else {
            guard claims.removeValue(forKey: key) != nil else { return }
        }
        apply(in: scene)
    }

    private static func apply(in scene: UIWindowScene?) {
        let tallest = claims.values.max() ?? 0
        let reserved = tallest > 0 ? tallest + contentGap : 0
        guard let scene = scene ?? foregroundWindowScene() else { return }
        for window in scene.windows {
            guard !(window is OverlayPassthroughWindow),
                  window.windowLevel == .normal,
                  let root = window.rootViewController,
                  root.additionalSafeAreaInsets.top != reserved
            else { continue }

            let updateLayout = {
                root.additionalSafeAreaInsets.top = reserved
                window.layoutIfNeeded()
            }
            if UIAccessibility.isReduceMotionEnabled {
                updateLayout()
            } else {
                UIView.animate(withDuration: 0.25, animations: updateLayout)
            }
        }
    }

    static func foregroundWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
