import SwiftUI
import UIKit

/// Ownership of the floating voice-note bar.
///
/// A note that is still playing after its bubble has scrolled out of the thread — or after the
/// chat was left, or a sheet was opened over it — has no control on screen. The bar is that
/// control: it names the note, scrubs, pauses, and dismisses. It is hosted in its own pass-through
/// window above the app for the same reason the call bubble is: sheets and full-screen covers are
/// presented above any in-app overlay and would otherwise hide it.
@MainActor
final class VoiceNoteOverlayWindowController {
    static let shared = VoiceNoteOverlayWindowController()

    private let presenter = VoiceNoteOverlayPresenter()
    private var window: OverlayPassthroughWindow?

    private init() {}

    func installNavigationHandler(_ handler: @escaping (String, UUID) -> Void) {
        presenter.open = handler
    }

    /// Brings the bar up or takes it down to match the player. Called by `VoiceNotePlayer` on every
    /// transition that can change the answer: a note starting or stopping, and its source bubble
    /// coming on or off screen.
    func refresh() {
        let player = VoiceNotePlayer.shared
        let shouldShow = VoiceNoteMiniBarPolicy.isVisible(
            hasPlayback: player.playing != nil,
            isSourceOnScreen: player.isSourceOnScreen
        )
        guard shouldShow else {
            hide()
            return
        }
        guard let window = ensureWindow() else { return }
        window.isHidden = false
        presenter.isVisible = true
        AppWindowTopStripReservation.set(
            VoiceNoteMiniBarPolicy.contentHeight,
            for: AppWindowTopStripReservation.voiceNoteKey,
            in: window.windowScene
        )
    }

    private func hide() {
        guard window != nil || presenter.isVisible else { return }
        presenter.isVisible = false
        presenter.hitRegion.frame = .zero
        AppWindowTopStripReservation.set(
            0,
            for: AppWindowTopStripReservation.voiceNoteKey,
            in: window?.windowScene
        )
        window?.isHidden = true
        window?.rootViewController = nil
        window?.windowScene = nil
        window = nil
    }

    private func ensureWindow() -> OverlayPassthroughWindow? {
        if let window, window.windowScene != nil { return window }
        guard let scene = AppWindowTopStripReservation.foregroundWindowScene() else { return nil }

        let created = window ?? OverlayPassthroughWindow(windowScene: scene)
        created.windowScene = scene
        // Above the app's own window so a sheet cannot bury a note that is still playing, and
        // below the system alert level so permission prompts still come out on top. The call
        // bubble sits at the same level; the two surfaces never coexist, because a live call
        // stops voice-note playback.
        created.windowLevel = .normal + 1
        created.backgroundColor = .clear
        created.isOpaque = false
        let hitRegion = presenter.hitRegion
        created.interactiveFrameProvider = { MainActor.assumeIsolated { hitRegion.frame } }

        let host = UIHostingController(
            rootView: VoiceNoteOverlayRootView(
                presenter: presenter,
                player: VoiceNotePlayer.shared
            )
        )
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        created.rootViewController = host
        window = created
        return created
    }
}

@MainActor
private final class VoiceNoteOverlayPresenter: ObservableObject {
    @Published var isVisible = false
    /// Where the bar is drawn, in window coordinates. Written outside the SwiftUI update cycle and
    /// read by the window's hit test, so touches anywhere else reach the app underneath.
    let hitRegion = OverlayHitRegion()
    var open: (String, UUID) -> Void = { _, _ in }
}

private struct VoiceNoteOverlayRootView: View {
    @ObservedObject var presenter: VoiceNoteOverlayPresenter
    @ObservedObject var player: VoiceNotePlayer

    var body: some View {
        VStack(spacing: 0) {
            if presenter.isVisible, let playing = player.playing {
                VoiceNoteMiniPlayerBar(
                    note: playing,
                    player: player,
                    open: { presenter.open(playing.context.conversationID, playing.id) }
                )
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    presenter.hitRegion.frame = proxy.frame(in: .global)
                                }
                                .onChange(of: proxy.frame(in: .global)) { _, frame in
                                    presenter.hitRegion.frame = frame
                                }
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy(duration: 0.24), value: presenter.isVisible)
    }
}

/// The bar itself: who is speaking, a scrubbable waveform, pause, and a dismiss.
struct VoiceNoteMiniPlayerBar: View {
    let note: VoiceNotePlayingNote
    @ObservedObject var player: VoiceNotePlayer
    let open: () -> Void

    /// Fraction playback was at when the current slide began, so a scrub is relative to where the
    /// finger went down rather than jumping to it.
    @State private var scrubOrigin: Double?

    private var isPlaying: Bool { !player.isPaused }

    var body: some View {
        ZStack {
            // Every non-control part of the strip is one generous route back to the exact source
            // message. Playback, scrubbing and dismiss stay independent controls above it.
            Button(action: open) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show this voice note in chat")
            .accessibilityValue("\(note.context.title), \(note.context.subtitle)")

            HStack(spacing: 12) {
                Button {
                    player.toggleCurrent()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(KitColor.green, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause voice note" : "Resume voice note")

                VStack(alignment: .leading, spacing: 3) {
                    Text(note.context.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                        .lineLimit(1)
                    Text(note.context.subtitle)
                        .font(.caption2)
                        .foregroundStyle(KitColor.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                scrubber

                Text(remainingLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(KitColor.secondaryText)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop voice note")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: VoiceNoteMiniBarPolicy.contentHeight)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(KitColor.secondaryText.opacity(0.18))
                .frame(height: 0.5)
        }
        .ignoresSafeArea(edges: .horizontal)
    }

    /// Same gesture contract as the bubble's waveform: a tap positions, a horizontal slide scrubs.
    private var scrubber: some View {
        let width = VoiceNoteSeekPolicy.waveformWidth * 0.62
        return VoiceNoteWaveform(
            progress: player.progress,
            accent: KitColor.green,
            seed: note.id
        )
        .frame(width: width, height: 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if scrubOrigin == nil { scrubOrigin = player.progress }
                    guard let origin = scrubOrigin,
                          VoiceNoteSeekPolicy.isScrub(translation: value.translation)
                    else { return }
                    player.seek(
                        toFraction: VoiceNoteSeekPolicy.scrubbedFraction(
                            from: origin,
                            translationWidth: value.translation.width,
                            width: width
                        )
                    )
                }
                .onEnded { value in
                    let origin = scrubOrigin ?? player.progress
                    scrubOrigin = nil
                    if VoiceNoteSeekPolicy.isTap(translation: value.translation) {
                        player.seek(
                            toFraction: VoiceNoteSeekPolicy.fraction(
                                atX: value.location.x,
                                width: width
                            )
                        )
                    } else if VoiceNoteSeekPolicy.isScrub(translation: value.translation) {
                        player.seek(
                            toFraction: VoiceNoteSeekPolicy.scrubbedFraction(
                                from: origin,
                                translationWidth: value.translation.width,
                                width: width
                            )
                        )
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Voice note position")
        .accessibilityValue("\(Int((player.progress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.seek(by: 5)
            case .decrement: player.seek(by: -5)
            @unknown default: break
            }
        }
    }

    private var remainingLabel: String {
        let remaining = max(0, player.duration * (1 - player.progress))
        return ChatMediaPlaybackClock.label(remaining)
    }
}
