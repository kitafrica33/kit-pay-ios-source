import SwiftUI

/// Wraps one message row so dragging it either way composes an answer to it. The distances and
/// the damping come from `SwipeToReplyPolicy`, so the gesture arms at the same point in the drag
/// here as it does on Android.
///
/// The drag runs alongside the conversation's own scrolling rather than instead of it: a drag is
/// only adopted once it is clearly sideways, so flicking through history still scrolls normally.
struct SwipeToReplyContainer<Content: View>: View {
    let isEnabled: Bool
    let onReply: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var travel: CGFloat = 0
    @State private var isTracking = false
    @State private var hasArmed = false

    private var progress: CGFloat { SwipeToReplyPolicy.progress(travel: travel) }

    var body: some View {
        ZStack(alignment: travel < 0 ? .trailing : .leading) {
            if travel != 0 { indicator }
            content()
                .offset(x: travel)
        }
        .simultaneousGesture(dragGesture, including: isEnabled ? .all : .subviews)
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

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard isEnabled else { return }
                if !isTracking {
                    // Adopt the drag only once it is decisively sideways. Anything else belongs
                    // to the conversation's scroll, which is still receiving it too.
                    guard abs(value.translation.width)
                        > abs(value.translation.height) * 1.5 else { return }
                    isTracking = true
                }
                travel = SwipeToReplyPolicy.travel(drag: value.translation.width)
                let armed = SwipeToReplyPolicy.shouldReply(travel: travel)
                if armed, !hasArmed {
                    // One tap of feedback at the crossing: the answer is committed from here,
                    // so the finger learns it without having to watch the arrow.
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                if !armed { hasArmed = false } else { hasArmed = true }
            }
            .onEnded { _ in
                let fires = isTracking && isEnabled && SwipeToReplyPolicy.shouldReply(travel: travel)
                isTracking = false
                hasArmed = false
                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                    travel = 0
                }
                if fires { onReply() }
            }
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
