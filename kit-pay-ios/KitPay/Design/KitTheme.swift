import SwiftUI
import UIKit

enum KitColor {
    static let navy = Color(red: 18 / 255, green: 45 / 255, blue: 70 / 255)
    static let deepNavy = Color(red: 8 / 255, green: 33 / 255, blue: 52 / 255)
    static let green = Color(red: 52 / 255, green: 185 / 255, blue: 139 / 255)
    /// Pale brand surface behind glyphs and chips, and the default glass tint.
    ///
    /// This used to be a fixed light mint. Every call site pairs it with `primaryText`, which flips
    /// to white in dark mode, so each of those glyphs became white-on-mint and all but vanished.
    /// The dark variant is a deep brand green, so the same glyph stays legible without any call
    /// site having to branch on the colour scheme.
    static let paleGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 22 / 255, green: 74 / 255, blue: 58 / 255, alpha: 1)
            : UIColor(red: 213 / 255, green: 246 / 255, blue: 234 / 255, alpha: 1)
    })
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)

    /// Public account verification wears blue, deliberately distinct from green KYC status.
    /// The blue seal is driven only by a validated server designation; completing KYC alone must
    /// never manufacture one locally.
    static let verifiedBlue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 96 / 255, green: 168 / 255, blue: 238 / 255, alpha: 1)
            : UIColor(red: 16 / 255, green: 94 / 255, blue: 176 / 255, alpha: 1)
    })

    /// Surface tint behind verified identity artwork, the blue counterpart of `paleGreen`.
    static let paleBlue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 20 / 255, green: 50 / 255, blue: 82 / 255, alpha: 1)
            : UIColor(red: 214 / 255, green: 232 / 255, blue: 250 / 255, alpha: 1)
    })

    /// Money shared out in a group wears gold, so it is never mistaken for an ordinary message or
    /// for the green of a one-to-one payment at a glance.
    ///
    /// Both variants are darkened well past decorative "shiny gold": the light one has to carry
    /// `primaryText` on it and the dark one has to sit on a near-black chat wallpaper.
    static let gold = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 224 / 255, green: 176 / 255, blue: 68 / 255, alpha: 1)
            : UIColor(red: 176 / 255, green: 126 / 255, blue: 18 / 255, alpha: 1)
    })

    /// Surface tint behind a group payment card and its glyphs, the gold counterpart of
    /// `paleGreen`.
    static let paleGold = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 74 / 255, green: 57 / 255, blue: 14 / 255, alpha: 1)
            : UIColor(red: 252 / 255, green: 240 / 255, blue: 205 / 255, alpha: 1)
    })

    /// The two ends of the sheen along a group payment card's edge. Kept subtle enough that the
    /// card still reads as a chat bubble rather than an advert.
    static let goldSheen = LinearGradient(
        colors: [
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 246 / 255, green: 206 / 255, blue: 108 / 255, alpha: 1)
                    : UIColor(red: 214 / 255, green: 166 / 255, blue: 54 / 255, alpha: 1)
            }),
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 150 / 255, green: 110 / 255, blue: 30 / 255, alpha: 1)
                    : UIColor(red: 140 / 255, green: 96 / 255, blue: 10 / 255, alpha: 1)
            }),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Shared geometry for the circular Liquid Glass controls in the Messages, Chats, Calls, and
/// Profile bars, so the chat header and the list headers stay visually identical.
enum KitControlMetrics {
    /// Diameter of a circular bar control. Also the minimum comfortable touch target.
    static let barControlDiameter: CGFloat = 44

    /// The call lenses remain visually distinct while sitting closer than the system default.
    static let controlSpacing: CGFloat = 2

    /// Gap between a leading profile photo and the label that follows it.
    static func identitySpacing(base: CGFloat) -> CGFloat { base }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 28
    var tint: Color = .white
    var tintStrength: Double? = nil
    var shadow: Bool = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            nativeGlass(content: content)
        } else {
            fallbackGlass(content: content)
        }
    }

    @available(iOS 26.0, *)
    private func nativeGlass(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .glassEffect(
                .regular
                    .tint(tint.opacity(nativeTintStrength)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay { highlightBorder }
            .shadow(
                color: shadow ? .black.opacity(colorScheme == .dark ? 0.24 : 0.09) : .clear,
                radius: 18,
                y: 8
            )
    }

    private func fallbackGlass(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        reduceTransparency
                            ? Color(uiColor: colorScheme == .dark
                                ? .secondarySystemBackground
                                : .systemBackground)
                            : Color.clear
                    )
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(fallbackTintStrength))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { highlightBorder }
            .shadow(
                color: shadow ? .black.opacity(colorScheme == .dark ? 0.24 : 0.09) : .clear,
                radius: 18,
                y: 8
            )
    }

    private var nativeTintStrength: Double {
        tintStrength ?? (colorScheme == .dark ? 0.055 : 0.13)
    }

    private var fallbackTintStrength: Double {
        tintStrength ?? (colorScheme == .dark ? 0.045 : 0.12)
    }

    private var highlightBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.30 : 0.72),
                                .white.opacity(colorScheme == .dark ? 0.06 : 0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                    .allowsHitTesting(false)
            }
            .foregroundStyle(.clear)
            .allowsHitTesting(false)
    }
}

extension View {
    func kitGlass(
        cornerRadius: CGFloat = 28,
        tint: Color = .white,
        tintStrength: Double? = nil,
        shadow: Bool = true
    ) -> some View {
        modifier(
            GlassCard(
                cornerRadius: cornerRadius,
                tint: tint,
                tintStrength: tintStrength,
                shadow: shadow
            )
        )
    }
}

/// A clean Liquid Glass lens.
///
/// The glass is the *only* surface: there is no material card, colour wash, or opaque disc behind
/// it, so the control reads as a lens over whatever scrolls underneath — the Apple behaviour for
/// bar controls. When a `diameter` is supplied the view is forced to that exact square frame, so a
/// `Circle` shape stays a true circle regardless of the label's intrinsic size.
///
/// iOS 26 gets the real `glassEffect` and its system-drawn specular edge; earlier releases keep the
/// same silhouette with a thin material plus a hairline rim, and Reduce Transparency falls back to
/// an opaque fill that still meets contrast requirements.
struct KitLensGlass<S: Shape>: ViewModifier {
    var shape: S
    var diameter: CGFloat?
    var interactive = true
    var shadow = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            sized(content)
                .glassEffect(
                    .regular.interactive(interactive && !reduceMotion),
                    in: shape
                )
                .shadow(color: shadowColor, radius: 9, y: 3)
        } else {
            sized(content)
                .background {
                    if reduceTransparency {
                        shape.fill(opaqueFill)
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .clipShape(shape)
                .overlay { rim }
                .shadow(color: shadowColor, radius: 9, y: 3)
        }
    }

    @ViewBuilder
    private func sized(_ content: Content) -> some View {
        if let diameter {
            content
                .frame(width: diameter, height: diameter, alignment: .center)
                .contentShape(shape)
        } else {
            content.contentShape(shape)
        }
    }

    private var rim: some View {
        shape
            .stroke(
                .white.opacity(colorScheme == .dark ? 0.24 : 0.52),
                lineWidth: 0.7
            )
            .allowsHitTesting(false)
    }

    private var opaqueFill: Color {
        Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .systemBackground)
    }

    private var shadowColor: Color {
        guard shadow else { return .clear }
        return .black.opacity(colorScheme == .dark ? 0.26 : 0.10)
    }
}

extension View {
    /// Wraps the view in a perfectly circular Liquid Glass control of `diameter` points.
    func kitCircularGlass(
        diameter: CGFloat,
        interactive: Bool = true,
        shadow: Bool = true
    ) -> some View {
        modifier(
            KitLensGlass(
                shape: Circle(),
                diameter: diameter,
                interactive: interactive,
                shadow: shadow
            )
        )
    }

    /// Wraps the view in a capsule Liquid Glass control that hugs its own content.
    func kitCapsuleGlass(
        interactive: Bool = false,
        shadow: Bool = true
    ) -> some View {
        modifier(
            KitLensGlass(
                shape: Capsule(style: .continuous),
                diameter: nil,
                interactive: interactive,
                shadow: shadow
            )
        )
    }
}

extension View {
    /// Applies Kit's own Liquid Glass only where the platform does not already supply it.
    ///
    /// iOS 26 draws a shared Liquid Glass background behind navigation bar items automatically.
    /// Adding ours on top stacked two surfaces, which reads as a flat grey panel in dark mode
    /// rather than glass, and put a visible seam between paired controls. On iOS 26 the system
    /// surface is therefore the only one — the control just claims an exact square so that surface
    /// is a true circle — and earlier releases, which draw nothing of their own, get ours.
    @ViewBuilder
    func kitBarControlGlass(diameter: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            frame(width: diameter, height: diameter, alignment: .center)
                .contentShape(Circle())
        } else {
            kitCircularGlass(diameter: diameter)
        }
    }

    /// Capsule counterpart of ``kitBarControlGlass(diameter:)`` for a bar control that hugs its own
    /// content rather than sitting in a fixed circle.
    @ViewBuilder
    func kitBarCapsuleGlass() -> some View {
        if #available(iOS 26.0, *) {
            contentShape(Capsule(style: .continuous))
        } else {
            kitCapsuleGlass(interactive: false)
        }
    }
}

/// A compact row of controls. Each child owns its own Liquid Glass lens, keeping the silhouettes
/// circular and the actions unambiguous while the group remains visually tight.
struct KitGlassControlGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
    }
}

/// Circular Liquid Glass bar button used by the Messages, Calls, and Profile headers.
///
/// The glass carries no colour wash of its own; the brand tint lives in the glyph so the pane stays
/// a clean lens over the content scrolling beneath it.
struct GlassIconButton: View {
    let systemName: String
    var tint = KitColor.green
    var diameter: CGFloat = KitControlMetrics.barControlDiameter
    /// Set for a control inside a navigation bar, where iOS 26 already supplies Liquid Glass and a
    /// second surface would stack into a solid panel.
    var inBar = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if inBar {
                glyph.kitBarControlGlass(diameter: diameter)
            } else {
                glyph.kitCircularGlass(diameter: diameter)
            }
        }
        .buttonStyle(.plain)
    }

    private var glyph: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
    }
}

private struct MarqueeContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A label that scrolls itself right-to-left when the text does not fit.
///
/// A narrow tile still has to identify the right person, so a name that overflows loops past
/// instead of being cut off; a name that fits is left completely still. A view-scoped task begins
/// every cycle at the start of the name and is cancelled automatically when the row leaves the
/// screen, avoiding a dedicated display timeline for every overflowing row.
///
/// Reduce Motion gets a static, tail-truncated label instead.
enum MarqueeTextPolicy {
    /// Only text that genuinely overflows scrolls. A label that fits must never move.
    static func scrolls(
        containerWidth: CGFloat,
        textWidth: CGFloat,
        reduceMotion: Bool
    ) -> Bool {
        guard !reduceMotion, containerWidth > 0 else { return false }
        return textWidth > containerWidth + 0.5
    }

    /// Seconds for one full pass plus its trailing gap, floored so a very short overflow does not
    /// flick past too quickly to read.
    static func cycleDuration(distance: CGFloat, pointsPerSecond: Double) -> Double {
        max(0.6, Double(max(0, distance)) / max(1, pointsPerSecond))
    }

    /// Hold duration that makes the stationary portion occupy `restFraction` of the complete
    /// hold-plus-move cycle.
    static func restDuration(movementDuration: Double, restFraction: Double) -> Double {
        let rest = min(max(0, restFraction), 0.9)
        guard rest > 0 else { return 0 }
        return max(0, movementDuration) * rest / (1 - rest)
    }
}

struct MarqueeText: View {
    let text: String
    var font: Font = .caption.bold()
    var color: Color = KitColor.primaryText
    /// Scroll speed in points per second.
    var pointsPerSecond: Double = 24
    /// Blank space between the end of one pass and the start of the next.
    var gap: CGFloat = 28
    /// Fraction of each cycle spent held still at the start, so the name is readable before it moves.
    var restFraction: Double = 0.22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    private var scrolls: Bool {
        MarqueeTextPolicy.scrolls(
            containerWidth: containerWidth,
            textWidth: textWidth,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MarqueeContainerWidthKey.self,
                        value: proxy.size.width
                    )
                }
            }
            .background(alignment: .leading) {
                // Measured off-screen: a background never changes the size of what it measures.
                base
                    .fixedSize()
                    .hidden()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MarqueeTextWidthKey.self,
                                value: proxy.size.width
                            )
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onPreferenceChange(MarqueeContainerWidthKey.self) { width in
                if abs(width - containerWidth) > 0.5 { containerWidth = width }
            }
            .onPreferenceChange(MarqueeTextWidthKey.self) { width in
                if abs(width - textWidth) > 0.5 { textWidth = width }
            }
            .clipped()
            // The scrolling branch draws the name twice; VoiceOver must read it exactly once.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .task(id: animationState) {
                await runAnimation()
            }
    }

    private var base: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    @ViewBuilder
    private var label: some View {
        if scrolls {
            let distance = textWidth + gap
            let movementDuration = MarqueeTextPolicy.cycleDuration(
                distance: distance,
                pointsPerSecond: pointsPerSecond
            )
            HStack(spacing: gap) {
                base
                base
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: scrollOffset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(
                scrollOffset == 0 ? nil : .linear(duration: movementDuration),
                value: scrollOffset
            )
        } else {
            base.truncationMode(.tail)
        }
    }

    private var animationState: MarqueeAnimationState {
        MarqueeAnimationState(
            text: text,
            containerWidth: containerWidth,
            textWidth: textWidth,
            reduceMotion: reduceMotion,
            pointsPerSecond: pointsPerSecond,
            gap: gap,
            restFraction: restFraction
        )
    }

    @MainActor
    private func runAnimation() async {
        resetScrollOffset()
        guard scrolls else { return }

        let distance = textWidth + gap
        let movementDuration = MarqueeTextPolicy.cycleDuration(
            distance: distance,
            pointsPerSecond: pointsPerSecond
        )
        let restDuration = MarqueeTextPolicy.restDuration(
            movementDuration: movementDuration,
            restFraction: restFraction
        )

        while !Task.isCancelled {
            guard await sleep(seconds: restDuration) else { return }
            scrollOffset = -distance
            guard await sleep(seconds: movementDuration) else { return }
            resetScrollOffset()
        }
    }

    @MainActor
    private func resetScrollOffset() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollOffset = 0 }
    }

    private func sleep(seconds: Double) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do {
            try await Task<Never, Never>.sleep(
                nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000)
            )
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

private struct MarqueeAnimationState: Hashable {
    let text: String
    let containerWidth: CGFloat
    let textWidth: CGFloat
    let reduceMotion: Bool
    let pointsPerSecond: Double
    let gap: CGFloat
    let restFraction: Double
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 52
    /// The hairline ring that separates the photo from a busy background. Turned off where the
    /// avatar already sits inside a Liquid Glass lens, so nothing but the glass frames it.
    var showsRing = true

    @Environment(\.colorScheme) private var colorScheme

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let result = words.compactMap(\.first).map(String.init).joined()
        return result.isEmpty ? "K" : result.uppercased()
    }

    /// FNV-1a over the name's unicode scalars: `String.hashValue` is seed-randomized
    /// per launch, and avatar colors must stay stable across launches and devices.
    private var hue: Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for scalar in name.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x100000001b3
        }
        return Double(hash % 360) / 360
    }

    /// A near-white disc is right on a light background and a glaring blob on a dark one, so the
    /// placeholder darkens and its initials brighten in dark mode instead.
    private var discColor: Color {
        colorScheme == .dark
            ? Color(hue: hue, saturation: 0.38, brightness: 0.30)
            : Color(hue: hue, saturation: 0.18, brightness: 0.98)
    }

    private var initialsColor: Color {
        colorScheme == .dark
            ? Color(hue: hue, saturation: 0.46, brightness: 0.94)
            : Color(hue: hue, saturation: 0.62, brightness: 0.57)
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(initialsColor)
            .frame(width: size, height: size)
            .background(discColor)
            .clipShape(Circle())
            .overlay {
                if showsRing {
                    Circle()
                        .stroke(
                            .white.opacity(colorScheme == .dark ? 0.22 : 0.65),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A group's avatar: the group photo when one is set, otherwise a generated group-styled
/// disc — a people glyph in the title's stable hue, never one member's face or initials —
/// plus a small persistent badge that says "group" even while a photo covers the disc.
/// Photos ride `ProfileAvatarCache`, so a group face seen once survives relaunch and offline.
struct GroupAvatarView: View {
    let title: String
    let photoURL: String?
    var size: CGFloat = 52
    /// The unambiguous group marker. On by default; turned off only where the surface already
    /// says "group" in words right next to the avatar.
    var showsBadge = true

    @State private var image: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, photoURL: String?, size: CGFloat = 52, showsBadge: Bool = true) {
        self.title = title
        self.photoURL = photoURL
        self.size = size
        self.showsBadge = showsBadge
        _image = State(initialValue: ProfileAvatarCache.cachedImage(for: photoURL))
    }

    /// Same FNV-1a the initials avatar uses, so a group keeps one stable colour everywhere.
    private var hue: Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for scalar in title.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x100000001b3
        }
        return Double(hash % 360) / 360
    }

    private var discColor: Color {
        colorScheme == .dark
            ? Color(hue: hue, saturation: 0.38, brightness: 0.30)
            : Color(hue: hue, saturation: 0.18, brightness: 0.98)
    }

    private var glyphColor: Color {
        colorScheme == .dark
            ? Color(hue: hue, saturation: 0.46, brightness: 0.94)
            : Color(hue: hue, saturation: 0.62, brightness: 0.57)
    }

    var body: some View {
        ZStack {
            Circle().fill(discColor)
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(glyphColor)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if showsBadge {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(KitColor.green, in: Circle())
                    .overlay {
                        Circle().stroke(.white, lineWidth: 1.5)
                    }
                    .offset(x: size * 0.04, y: size * 0.04)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.18), value: image == nil)
        .task(id: photoURL) { await load() }
        .accessibilityLabel("Group photo for \(title)")
    }

    private func load() async {
        if let cached = ProfileAvatarCache.cachedImage(for: photoURL) {
            image = cached
            return
        }
        image = nil
        guard let photoURL else { return }
        let loaded = await ProfileAvatarCache.shared.image(for: photoURL)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

/// Displays initials immediately, then replaces them with the immutable remote profile photo.
/// Keeping the placeholder in the same fixed circle prevents layout shifts while the image loads.
///
/// This is the only profile-photo view in the app. Photos come from `ProfileAvatarCache` rather
/// than `AsyncImage`, which means a face the customer has seen once stays visible on relaunch and
/// with no network, and the bytes sit encrypted on disk instead of in the clear in `URLCache`.
/// Loading is lazy by construction: the fetch starts in `.task`, so a row that never scrolls into
/// view never downloads anything.
///
/// Verification is intentionally absent here. The authoritative seal belongs immediately after
/// a displayed account name, never on the profile-photo circle or its accessibility label.
struct RemoteAvatarView: View {
    let name: String
    let avatarURL: String?
    var size: CGFloat = 52
    /// Opacity of the hairline ring, or `nil` where the avatar already sits inside a glass lens
    /// and a second outline would only muddy the edge.
    var ringOpacity: Double? = 0.65

    @State private var image: UIImage?

    init(
        name: String,
        avatarURL: String?,
        size: CGFloat = 52,
        ringOpacity: Double? = 0.65
    ) {
        self.name = name
        self.avatarURL = avatarURL
        self.size = size
        self.ringOpacity = ringOpacity
        // Seeded synchronously so a row scrolling back into view draws its photo in the first
        // frame rather than flashing initials for one hop.
        _image = State(initialValue: ProfileAvatarCache.cachedImage(for: avatarURL))
    }

    var body: some View {
        ZStack {
            AvatarView(name: name, size: size, showsRing: false)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if let ringOpacity {
                Circle()
                    .stroke(.white.opacity(ringOpacity), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: image == nil)
        .task(id: avatarURL) { await load() }
        .accessibilityLabel("Profile photo for \(name)")
    }

    private func load() async {
        if let cached = ProfileAvatarCache.cachedImage(for: avatarURL) {
            image = cached
            return
        }
        // A different person now occupies this row; drop the previous face before fetching so a
        // slow download can never leave the wrong photo next to a name.
        image = nil
        guard let avatarURL else { return }
        let loaded = await ProfileAvatarCache.shared.image(for: avatarURL)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

/// Keeps an authoritative public-verification seal immediately after the displayed account name.
/// Profile photos deliberately carry no verification decoration; the name is the sole placement.
struct VerifiedAccountNameLabel<NameContent: View>: View {
    let designation: AccountVerificationDesignation?
    var spacing: CGFloat = 5
    var badgeDiameter: CGFloat = 15
    private let nameContent: NameContent

    init(
        designation: AccountVerificationDesignation?,
        spacing: CGFloat = 5,
        badgeDiameter: CGFloat = 15,
        @ViewBuilder nameContent: () -> NameContent
    ) {
        self.designation = designation
        self.spacing = spacing
        self.badgeDiameter = badgeDiameter
        self.nameContent = nameContent()
    }

    var body: some View {
        HStack(spacing: spacing) {
            nameContent
            if let designation {
                VerifiedAccountBadge(designation: designation, diameter: badgeDiameter)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact public-verification seal. Construction is private so it can only appear through the
/// name-label component above, never as an avatar overlay or free-floating decoration.
private struct VerifiedAccountBadge: View {
    let designation: AccountVerificationDesignation
    var diameter: CGFloat = 16

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, KitColor.verifiedBlue)
        .font(.system(size: diameter, weight: .semibold))
        .frame(width: diameter, height: diameter)
        .fixedSize()
        .layoutPriority(1)
        .shadow(color: KitColor.verifiedBlue.opacity(0.22), radius: 2, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(designation.accessibilityLabel)
    }
}

/// Draws content that fills the space it is given without letting that content decide how much
/// space there is.
///
/// `scaledToFill` reports the size a photo needs in order to cover its container, which for a
/// portrait photo asked to cover a phone screen is far wider than the screen. A `ZStack` takes the
/// size of its largest child, so that report travels upwards: on the call screen it grew the whole
/// layout the instant a profile photo finished loading, sliding the name, the avatar and the
/// control bar off the right edge. An overlay is positioned by its host and never sizes it, so
/// hosting the fill on a flexible layer keeps the look and drops the report.
struct KitFillingBackdrop<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Color.clear
            .overlay { content }
            .clipped()
    }
}

struct ConnectivityPill: View {
    let isOnline: Bool
    let queuedCount: Int
    /// See ``GlassIconButton/inBar``.
    var inBar = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isOnline ? "checkmark.icloud.fill" : "icloud.slash.fill")
            Text(isOnline ? (queuedCount == 0 ? "Up to date" : "Syncing \(queuedCount)") : "Offline · \(queuedCount) queued")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isOnline ? KitColor.green : .orange)
        .padding(.horizontal, 12)
        .frame(minHeight: KitControlMetrics.barControlDiameter)
        .modifier(ConnectivityPillSurface(inBar: inBar))
        .accessibilityLabel(isOnline ? "Online" : "Offline")
    }
}

private struct ConnectivityPillSurface: ViewModifier {
    let inBar: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if inBar {
            content.kitBarCapsuleGlass()
        } else {
            content.kitCapsuleGlass(interactive: false)
        }
    }
}
