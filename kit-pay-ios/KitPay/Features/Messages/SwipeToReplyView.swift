import SwiftUI
import UIKit

/// Wraps one message row so dragging it either way composes an answer to it. The distances and
/// the damping come from `SwipeToReplyPolicy`, so the gesture arms at the same point in the drag
/// here as it does on Android. Direction arbitration remains iOS-specific because it must yield
/// promptly to SwiftUI's vertical `ScrollView` recognizer.
///
/// One native recognizer on the containing scroll view rejects vertical input before it begins.
/// Each row supplies only a passive region and callbacks; its SwiftUI controls keep hit testing.
struct SwipeToReplyContainer<Content: View>: View {
    let isEnabled: Bool
    let onReply: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var travel: CGFloat = 0
    @State private var hasArmed = false
    @State private var gestureLifetime = SwipeToReplyGestureLifetime()

    private var progress: CGFloat { SwipeToReplyPolicy.progress(travel: travel) }

    var body: some View {
        ZStack(alignment: travel < 0 ? .trailing : .leading) {
            if travel != 0 { indicator }
            content()
                .offset(x: travel)
        }
        .contentShape(Rectangle())
        .background(SwipeToReplyGestureRegion(
            lifetime: gestureLifetime,
            callbacks: isEnabled ? SwipeToReplyGestureCallbacks(
                changed: dragChanged,
                ended: { translation in
                    dragChanged(translation)
                    let fires = isEnabled && SwipeToReplyPolicy.shouldReply(
                        travel: SwipeToReplyPolicy.travel(drag: translation)
                    )
                    resetGesture()
                    if fires { onReply() }
                },
                cancelled: resetGesture
            ) : nil
        ))
        .onDisappear {
            hasArmed = false
            travel = 0
        }
    }

    private var indicator: some View {
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(KitColor.green)
            .frame(width: 30, height: 30)
            .background(KitColor.green.opacity(0.16), in: Circle())
            .opacity(Double(progress))
            .scaleEffect(0.7 + 0.3 * progress)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func dragChanged(_ translation: CGFloat) {
        travel = SwipeToReplyPolicy.travel(drag: translation)
        let armed = SwipeToReplyPolicy.shouldReply(travel: travel)
        if armed, !hasArmed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        hasArmed = armed
    }

    private func resetGesture() {
        hasArmed = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { travel = 0 }
    }
}

struct SwipeToReplyGestureCallbacks {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    let cancelled: () -> Void
}

/// Kept in SwiftUI State so a replacement probe shares the cancellation generation with the
/// row it represents. A disappearing UIView must not discard that row's pending reset.
@MainActor
final class SwipeToReplyGestureLifetime {
    let identity = UUID()
    var feedbackToken: UUID?
}

private struct SwipeToReplyGestureRegion: UIViewRepresentable {
    let lifetime: SwipeToReplyGestureLifetime
    let callbacks: SwipeToReplyGestureCallbacks?

    func makeUIView(context: Context) -> SwipeToReplyGestureProbe {
        SwipeToReplyGestureProbe(frame: .zero)
    }

    func updateUIView(_ view: SwipeToReplyGestureProbe, context: Context) {
        view.configure(identity: lifetime.identity, callbacks: callbacks, lifetime: lifetime)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SwipeToReplyGestureProbe, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ view: SwipeToReplyGestureProbe, coordinator: ()) {
        view.detach()
    }
}

/// SwiftUI waveform scrubbing is not necessarily backed by a UIControl. Mark its exact region
/// without covering it or participating in hit testing, so reply never admits that touch.
struct SwipeToReplyGestureExclusion: UIViewRepresentable {
    func makeUIView(context: Context) -> SwipeToReplyGestureProbe {
        SwipeToReplyGestureProbe(frame: .zero)
    }

    func updateUIView(_ view: SwipeToReplyGestureProbe, context: Context) {
        view.configure(identity: nil, callbacks: nil, excludesReply: true)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SwipeToReplyGestureProbe, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ view: SwipeToReplyGestureProbe, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class SwipeToReplyGestureProbe: UIView {
    private(set) var identity: UUID?
    private(set) var callbacks: SwipeToReplyGestureCallbacks?
    private(set) var excludesReply = false
    private(set) weak var coordinator: SwipeToReplyPanCoordinator?
    fileprivate var lifetime = SwipeToReplyGestureLifetime()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        identity: UUID?, callbacks: SwipeToReplyGestureCallbacks?, excludesReply: Bool = false,
        lifetime: SwipeToReplyGestureLifetime? = nil
    ) {
        if self.identity != identity || self.excludesReply != excludesReply
            || (self.callbacks != nil && callbacks == nil)
            || (lifetime != nil && self.lifetime !== lifetime) {
            coordinator?.invalidate(self)
        }
        if let lifetime { self.lifetime = lifetime }
        self.identity = identity
        self.callbacks = callbacks
        self.excludesReply = excludesReply
        attach()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); attach() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
    override func layoutSubviews() { super.layoutSubviews(); attach() }

    private func attach() {
        var ancestor = window == nil ? nil : superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                if coordinator?.scrollView === scroll { return }
                detach()
                let owner = SwipeToReplyPanCoordinator.shared(for: scroll)
                coordinator = owner
                owner.register(self)
                return
            }
            ancestor = view.superview
        }
        detach()
    }

    func detach() {
        coordinator?.unregister(self)
        coordinator = nil
    }
}

/// The weak-key registry shares one recognizer across materialized rows. Admission inspects
/// regions once; pan actions address only the selected row, even in a long LazyVStack.
@MainActor
final class SwipeToReplyPanCoordinator: NSObject, UIGestureRecognizerDelegate {
    private static let owners = NSMapTable<UIScrollView, SwipeToReplyPanCoordinator>.weakToStrongObjects()
    private(set) weak var scrollView: UIScrollView?
    let pan = UIPanGestureRecognizer()
    private var probes: [ObjectIdentifier: WeakProbe] = [:]
    private weak var candidate: SwipeToReplyGestureProbe?
    private var candidateIdentity: UUID?
    private var session: Session?

    private final class WeakProbe {
        weak var value: SwipeToReplyGestureProbe?
        init(_ value: SwipeToReplyGestureProbe) { self.value = value }
    }

    private struct Session {
        weak var probe: SwipeToReplyGestureProbe?
        let identity: UUID
        let token: UUID
        let lifetime: SwipeToReplyGestureLifetime
        let cancelled: () -> Void
        var visiblyActive = false
    }

    static func shared(for scroll: UIScrollView) -> SwipeToReplyPanCoordinator {
        if let existing = owners.object(forKey: scroll) { return existing }
        let owner = SwipeToReplyPanCoordinator(scroll: scroll)
        owners.setObject(owner, forKey: scroll)
        return owner
    }

    private init(scroll: UIScrollView) {
        scrollView = scroll
        super.init()
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        pan.addTarget(self, action: #selector(panChanged(_:)))
        scroll.addGestureRecognizer(pan)
    }

    func register(_ probe: SwipeToReplyGestureProbe) {
        probes[ObjectIdentifier(probe)] = WeakProbe(probe)
    }

    func unregister(_ probe: SwipeToReplyGestureProbe) {
        invalidate(probe)
        probes.removeValue(forKey: ObjectIdentifier(probe))
        probes = probes.filter { $0.value.value != nil }
        if probes.isEmpty, let scroll = scrollView {
            scroll.removeGestureRecognizer(pan)
            Self.owners.removeObject(forKey: scroll)
        }
    }

    func invalidate(_ probe: SwipeToReplyGestureProbe) {
        if candidate === probe { candidate = nil; candidateIdentity = nil }
        guard session?.probe === probe else { return }
        cancelSession(deferred: true)
        // Only reset our own recognizer on actual invalidation, never on row redraws.
        pan.isEnabled = false
        pan.isEnabled = true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pan, let scroll = scrollView else { return false }
        if pan.numberOfTouches > 0 { return true } // UIKit enforces the one-touch maximum.
        return selectRow(at: touch.location(in: scroll), hitView: touch.view)
    }

    func selectRow(at point: CGPoint, hitView: UIView?) -> Bool {
        candidate = nil
        candidateIdentity = nil
        guard session == nil, let scroll = scrollView, scroll.window != nil,
              point.x.isFinite, point.y.isFinite, scroll.bounds.contains(point)
        else { return false }
        // A nested native control/scroll owns its own interaction. SwiftUI-only controls can
        // register an exclusion, as the waveform does; do not inspect private UIKit classes.
        var ancestor = hitView
        while let view = ancestor, view !== scroll {
            if view is UIControl || view is UIScrollView { return false }
            ancestor = view.superview
        }
        guard ancestor === scroll else { return false }
        var selected: SwipeToReplyGestureProbe?
        for entry in probes.values {
            guard let probe = entry.value, probe.window === scroll.window,
                  probe.coordinator === self,
                  probe.bounds.contains(probe.convert(point, from: scroll))
            else { continue }
            if probe.excludesReply { return false }
            if probe.identity != nil, probe.callbacks != nil {
                guard selected == nil else { return false } // Never guess across overlapping rows.
                selected = probe
            }
        }
        candidate = selected
        candidateIdentity = selected?.identity
        return selected != nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return false }
        let translation = pan.translation(in: scrollView?.window)
        return shouldBegin(translation: CGSize(width: translation.x, height: translation.y))
    }

    func shouldBegin(translation: CGSize) -> Bool {
        guard let candidate, isEligible(candidate, identity: candidateIdentity),
              SwipeToReplyPolicy.nativePanShouldBegin(translation: translation)
        else { self.candidate = nil; candidateIdentity = nil; return false }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === pan && otherGestureRecognizer === scrollView?.panGestureRecognizer
    }

    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: scrollView?.window)
        handle(state: recognizer.state, translation: translation.x)
    }

    func handle(state: UIGestureRecognizer.State, translation: CGFloat) {
        if state == .began {
            guard let candidate, let identity = candidateIdentity,
                  isEligible(candidate, identity: identity), let callbacks = candidate.callbacks
            else { return }
            if candidate.lifetime.feedbackToken != nil {
                // A replacement row can receive a new touch before its old deferred reset.
                // Clear that feedback before taking over its token, even below activation.
                callbacks.changed(0)
            }
            guard self.candidate === candidate, isEligible(candidate, identity: identity) else { return }
            let token = UUID()
            candidate.lifetime.feedbackToken = token
            session = Session(probe: candidate, identity: identity, token: token,
                              lifetime: candidate.lifetime, cancelled: callbacks.cancelled)
        }
        guard let current = session else {
            if state == .ended || state == .cancelled || state == .failed {
                candidate = nil; candidateIdentity = nil
            }
            return
        }
        guard translation.isFinite, let probe = current.probe,
              isEligible(probe, identity: current.identity)
        else { cancelSession(); return }
        switch state {
        case .began, .changed:
            if current.visiblyActive || abs(translation) >= SwipeToReplyPolicy.activationDistance {
                session?.visiblyActive = true
                probe.callbacks?.changed(translation)
            }
        case .ended:
            session = nil
            candidate = nil
            candidateIdentity = nil
            current.lifetime.feedbackToken = nil
            if current.visiblyActive || abs(translation) >= SwipeToReplyPolicy.activationDistance {
                probe.callbacks?.ended(translation)
            } else {
                current.cancelled()
            }
        case .cancelled, .failed:
            cancelSession()
        default:
            break
        }
    }

    private func isEligible(_ probe: SwipeToReplyGestureProbe, identity: UUID?) -> Bool {
        guard let scroll = scrollView else { return false }
        return identity != nil && probe.identity == identity && probe.callbacks != nil
            && !probe.excludesReply && probe.coordinator === self
            && probe.window != nil && probe.window === scroll.window
    }

    private func cancelSession(deferred: Bool = false) {
        let cancelled = session
        session = nil
        candidate = nil
        candidateIdentity = nil
        guard let cancelled else { return }
        let reset = {
            guard cancelled.lifetime.feedbackToken == cancelled.token else { return }
            cancelled.lifetime.feedbackToken = nil
            cancelled.cancelled()
        }
        // A lazy-row teardown/update can occur inside SwiftUI layout. A newer gesture's token
        // prevents this deferred reset from erasing its feedback.
        if deferred { DispatchQueue.main.async(execute: reset) } else { reset() }
    }
}

/// The quoted line an answer carries: an accent rail, who is being answered, and one line of
/// what they said. Used both above the answer in the thread and above the composer while the
/// answer is still being written.
struct QuotedMessagePreview: View {
    let authorLabel: String
    let preview: String
    /// Tinting for the rail and the author's name.
    let accent: Color
    let textColor: Color
    let background: Color
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(authorLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(textColor.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(authorLabel): \(preview)")
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }
}
