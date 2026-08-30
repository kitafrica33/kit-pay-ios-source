import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isConversationPresented = false
    @State private var isProfileDetailPresented = false
    @State private var measuredTabBarHeight = RootTabBarLayoutPolicy.estimatedBarHeight

    var body: some View {
        Group {
            if model.acceptedAccountDeletionCleanupBlocked {
                AcceptedAccountDeletionRecoveryView()
            } else if model.unresolvedAccountDeletionAttemptBlocked {
                UnresolvedAccountDeletionAttemptView()
            } else if model.protectedLocalStateRecoveryBlocked {
                ProtectedLocalStateRecoveryView()
            } else if model.requiresBiometricSignIn {
                BiometricSignInView()
            } else if model.isLoading && !model.isSignedIn && model.capabilities == nil {
                ZStack {
                    KitColor.canvas.ignoresSafeArea()
                    ProgressView().controlSize(.large).tint(KitColor.green)
                }
            } else if model.isSignedIn {
                if let step = model.accountSetupStep {
                    AccountSetupView(step: step)
                        .id(step)
                } else {
                    signedInTabs
                }
            } else {
                OnboardingView()
            }
        }
        // The strip's push-down is applied by CallOverlayWindowController through the app
        // window's `additionalSafeAreaInsets`: a SwiftUI safe-area inset here could not move
        // UIKit navigation bars, which stayed pinned underneath the strip.
        .onChange(of: model.selectedTab) { previous, selected in
            // The id-driven task below is the sole automatic Home authorizer. This transition
            // only invalidates the visit that is no longer visible.
            if previous == MainTab.home.rawValue,
               selected != MainTab.home.rawValue {
                model.homeDidResignActive()
            }
        }
        .task(id: homeAuthorizationTrigger) {
            guard model.isSignedIn,
                  !model.requiresBiometricSignIn,
                  model.accountSetupStep == nil,
                  model.selectedTab == MainTab.home.rawValue
            else { return }
            await model.homeDidBecomeActive()
        }
        .task(id: accountDiscoveryDrainTrigger) {
            // The discoverability choices made during setup could not be sent then:
            // `communicationPrivacyContext()` refuses to run until setup is finished and the
            // session grants full access. This is the first moment both are true.
            await model.applyPendingAccountDiscoveryChoiceIfPossible()
        }
        .task(id: model.messagingRealtimeLifecycleIdentity) {
            guard !Task.isCancelled else { return }
            let center = KitPresenceCenter.shared
            let appModel = model
            center.syncRequestHandler = { [weak appModel] userID, sessionID in
                appModel?.requestRealtimeMessagingSync(
                    userID: userID,
                    sessionID: sessionID
                )
            }
            center.connectionStateHandler = { [weak appModel] isLive in
                appModel?.realtimeMessagingConnectionDidChange(isLive: isLive)
            }
            // The primary answer path: the validated `kit.call.answered` frame, with the
            // `call.answered` push remaining the fallback for a device whose socket is down.
            center.callAnswerHandler = { [weak appModel] signal in
                appModel?.handleCallAnswerSignal(callId: signal.callId, signal: signal)
            }
            center.setForeground(
                UIApplication.shared.applicationState == .active
                    && !model.requiresBiometricSignIn
            )
            guard !Task.isCancelled else { return }
            guard model.isSignedIn,
                  model.accountSetupStep == nil,
                  model.communicationAccessGranted,
                  !model.requiresBiometricSignIn,
                  let configuration = model.messagingRealtimeConfiguration,
                  let userID = model.profile?.id,
                  let sessionID = await model.realtimeSessionID(for: userID)
            else {
                guard !Task.isCancelled else { return }
                center.reset()
                return
            }
            guard !Task.isCancelled else { return }
            center.broadcastsPresence =
                model.communicationPreferences?.messagingPresenceVisible ?? false
            center.start(
                userID: userID,
                sessionID: sessionID,
                configuration: configuration
            )
            if let conversationID = model.realtimeVisibleConversationID {
                center.observeConversation(conversationID)
            }
        }
        .alert(
            "Kit Pay",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        // Presented from the root rather than from the Chats tab: a share can arrive while the
        // customer is looking at Home or a call, and the picker has to be reachable from wherever
        // they actually are.
        .fullScreenCover(
            isPresented: Binding(
                get: { model.pendingSharedInboxBatch != nil },
                set: { if !$0 { model.discardPendingSharedInbox() } }
            )
        ) {
            if let batch = model.pendingSharedInboxBatch {
                SharedContentDestinationView(
                    batch: batch,
                    onChoose: { model.routeSharedInbox(to: $0.id) },
                    onCancel: { model.discardPendingSharedInbox() }
                )
                .environmentObject(model)
            }
        }
    }

    private var homeAuthorizationTrigger: String {
        [
            String(model.isSignedIn),
            String(model.biometricUnlockEnabled),
            String(model.requiresBiometricSignIn),
            String(model.accountSetupStep == nil),
            String(model.selectedTab),
            model.profile?.id ?? "none",
        ].joined(separator: ":")
    }

    private var accountDiscoveryDrainTrigger: String {
        [
            model.profile?.id ?? "none",
            String(model.isSignedIn),
            String(model.accountSetupStep == nil),
            String(model.communicationAccessGranted),
            String(model.isOnline),
        ].joined(separator: ":")
    }

    private var signedInTabs: some View {
        ZStack {
            tabContent(HomeView(), for: .home)
            tabContent(
                MessagesView(isConversationPresented: $isConversationPresented),
                for: .messages
            )
            tabContent(CallsView(), for: .calls)
            tabContent(
                ProfileView(isDetailPresented: $isProfileDetailPresented),
                for: .profile
            )
        }
        // The menu floats *over* the tabs rather than insetting them.
        //
        // It used to be a bottom `safeAreaInset` on this ZStack, which looked right but reserved
        // nothing: each tab owns a `NavigationStack`, and a safe-area inset applied outside a
        // navigation stack does not reach the scroll views inside it. Every tab therefore scrolled
        // to its true end with the last row stranded under the capsule. Each tab's scroll view now
        // takes the clearance itself, through the environment, as scroll *content* margin — so
        // rows still travel behind the glass and the final row can always be scrolled clear.
        .environment(
            \.rootTabBarClearance,
            shouldShowRootTabBar
                ? RootTabBarLayoutPolicy.contentClearance(barHeight: measuredTabBarHeight)
                : 0
        )
        .overlay(alignment: .bottom) {
            if shouldShowRootTabBar {
                FloatingTabBar(
                    selection: $model.selectedTab,
                    unreadMessageCount: model.state.conversations.reduce(0) { $0 + $1.unreadCount },
                    queuedCount: model.queuedCount,
                    profileName: model.profile?.identityDisplayName ?? "Kit Pay",
                    profileAvatarURL: model.profile?.avatarURL
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: RootTabBarHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
            }
        }
        .onPreferenceChange(RootTabBarHeightKey.self) { height in
            // Dynamic Type resizes the capsule, so the clearance follows its measured height
            // rather than a guess that goes stale at accessibility sizes.
            guard height > 0, abs(height - measuredTabBarHeight) > 0.5 else { return }
            measuredTabBarHeight = height
        }
    }

    private var shouldShowRootTabBar: Bool {
        RootTabBarPolicy.isVisible(
            selectedTab: model.selectedTab,
            messagesTab: MainTab.messages.rawValue,
            isConversationPresented: isConversationPresented,
            profileTab: MainTab.profile.rawValue,
            isProfileDetailPresented: isProfileDetailPresented,
            isAccountDeletionSubmissionActive: model.isSubmittingAccountDeletion
        )
    }

    private func tabContent<Content: View>(_ content: Content, for tab: MainTab) -> some View {
        let isSelected = model.selectedTab == tab.rawValue

        return content
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
            .zIndex(isSelected ? 1 : 0)
            .animation(nil, value: model.selectedTab)
    }
}

private struct UnresolvedAccountDeletionAttemptView: View {
    var body: some View {
        ZStack {
            KitColor.canvas.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 76, height: 76)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.65), lineWidth: 0.8)
                    }

                Text("Confirming account deletion")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)

                Text(
                    "Kit Pay will keep this account's local data hidden until Kit Pay confirms "
                        + "whether the interrupted deletion request was accepted. Do not submit it again."
                )
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)

                if let deletionURL = AccountDeletionContract.trustedFallbackURL {
                    Link(destination: deletionURL) {
                        Label("Continue your deletion request", systemImage: "arrow.up.right.square")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 17))
                    .tint(KitColor.green)

                    Text(
                        "This opens Kit Pay's official account deletion page, used only to review "
                            + "or continue a deletion request. It is not a support channel."
                    )
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .kitGlass(cornerRadius: 30)
            .padding(22)
        }
    }
}

private struct ProtectedLocalStateRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isRetrying = false

    var body: some View {
        ZStack {
            KitColor.canvas.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                    .frame(width: 76, height: 76)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.65), lineWidth: 0.8)
                    }

                Text("Unlocking protected data")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)

                Text(
                    model.protectedLocalStateRecoveryRequiresSupport
                        ? "Kit Pay could not safely read this device's protected account data. "
                            + "It remains hidden and signing in here stays paused."
                        : "Unlock this device and try again. Kit Pay will not show or change local "
                            + "account data until its protected storage is available."
                )
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)

                if model.protectedLocalStateRecoveryRequiresSupport {
                    Label {
                        Text(
                            "To get help, open Kit Pay on a device where you are signed in and "
                                + "go to Profile → Help & support. Kit Pay support works only "
                                + "inside the app, so this signed-out screen can't start a "
                                + "support request."
                        )
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                        .multilineTextAlignment(.leading)
                    } icon: {
                        Image(systemName: "iphone.gen3")
                            .foregroundStyle(KitColor.green)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Button {
                        Task {
                            isRetrying = true
                            await model.retryProtectedLocalStateRecovery()
                            isRetrying = false
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if isRetrying { ProgressView().tint(.white) }
                            Text("Retry securely").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 17))
                    .tint(KitColor.green)
                    .disabled(isRetrying)
                }
            }
            .padding(24)
            .kitGlass(cornerRadius: 30)
            .padding(22)
        }
    }
}

private struct AcceptedAccountDeletionRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isRetrying = false

    var body: some View {
        ZStack {
            KitColor.canvas.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                    .frame(width: 76, height: 76)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.65), lineWidth: 0.8)
                    }

                Text("Finishing account deletion")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)

                Text(
                    "This device is protecting your previous account data while local removal "
                        + "finishes. Signing in stays unavailable until cleanup is confirmed."
                )
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)

                Button {
                    Task {
                        isRetrying = true
                        await model.retryAcceptedAccountDeletionCleanup()
                        isRetrying = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isRetrying { ProgressView().tint(.white) }
                        Text("Retry secure cleanup").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 17))
                .tint(KitColor.green)
                .disabled(isRetrying)
            }
            .padding(24)
            .kitGlass(cornerRadius: 30)
            .padding(22)
        }
    }
}

enum RootTabBarPolicy {
    /// The floating menu belongs to the top level of a tab. A pushed detail screen — a
    /// conversation, or a Profile settings page — owns the whole height, so the bar steps aside
    /// rather than floating over content the user is reading or a bottom action they need to
    /// reach. A screen pushed under a *different* tab must never hide the bar for the tab the
    /// user is actually looking at, hence the per-tab checks.
    static func isVisible(
        selectedTab: Int,
        messagesTab: Int,
        isConversationPresented: Bool,
        profileTab: Int = -1,
        isProfileDetailPresented: Bool = false,
        isAccountDeletionSubmissionActive: Bool
    ) -> Bool {
        guard !isAccountDeletionSubmissionActive else { return false }
        if selectedTab == messagesTab, isConversationPresented { return false }
        if selectedTab == profileTab, isProfileDetailPresented { return false }
        return true
    }
}

enum RootTabBarLayoutPolicy {
    static let minimumInteractiveDimension: CGFloat = 44

    /// Global trim applied to the menu's own metrics at standard text sizes. It is now neutral:
    /// the sizes below are stated directly at the value they should render at, rather than being
    /// a larger number shrunk by a factor, which had left the icons and captions below the size
    /// iOS uses for its own tab bars. Large accessibility sizes keep their larger hit targets.
    static let visualScale: CGFloat = 1.0
    /// A floating capsule reads better shorter and lighter than a docked bar: the icons carry the
    /// row, so the button gives them room to be large without carrying dead height around them.
    /// Still comfortably above the 44pt minimum target.
    static let baseButtonHeight: CGFloat = 50
    static let accessibilityButtonHeight: CGFloat = 72

    /// The icon is the thing people aim at, so it is a little larger than the system tab bar's,
    /// with the caption held at the size iOS uses. The proportion between them is what keeps the
    /// row legible at arm's length.
    static let iconPointSize: CGFloat = 23
    static let captionPointSize: CGFloat = 11

    /// Glass between the row of buttons and the edge of the capsule. Enough for the selected
    /// button's own lens to sit inside the bar's without the two edges touching.
    static let capsuleInset: CGFloat = 6

    /// Gap between neighbouring buttons. Small: the buttons share the row equally and a slide
    /// crosses the gaps, so a wide one reads as a dead zone under the finger.
    static let interButtonSpacing: CGFloat = 4

    /// Inset from the screen edges, so the capsule reads as floating over the page rather than
    /// bridging it. Regular width has room for more.
    static let compactHorizontalInset: CGFloat = 16
    static let regularHorizontalInset: CGFloat = 28

    /// Rest the menu lower by one fifth of its original button height. The device safe area still
    /// protects the home indicator, while the scroll clearance above keeps the final page action
    /// completely reachable.
    static let verticalDropFraction: CGFloat = 0.20
    static var verticalDrop: CGFloat { baseButtonHeight * verticalDropFraction }

    /// Breathing room between the last row of a page and the top of the glass capsule. The glass
    /// blurs and shadows well past its own bounds, so the final page action needs real clearance
    /// rather than finishing flush against the capsule edge.
    static let scrollClearance: CGFloat = 28

    /// Gap between the reserved clearance and the capsule itself.
    static let barTopPadding: CGFloat = 8 * visualScale

    /// Extra bottom padding a page inside a tab should add for the floating menu: none. The
    /// clearance is delivered as scroll content margin through `rootTabBarScrollClearance()`;
    /// page-level padding on top of that stacks and reads as the list ending early.
    static let pageBottomPadding: CGFloat = 0

    /// Height assumed for the bar before its first measurement, so a page's very first frame is
    /// already inset instead of momentarily scrolling under the capsule. Button height plus the
    /// capsule's own inset on both edges plus `barTopPadding`.
    static let estimatedBarHeight: CGFloat = baseButtonHeight + (capsuleInset * 2) + barTopPadding

    /// Bottom scroll *content* margin a page inside a tab needs so its last row can be scrolled
    /// clear of the floating menu.
    ///
    /// This is content margin, not viewport inset: the scroll view still lays out edge to edge, so
    /// rows stay visible travelling behind the glass and behind the home indicator, and only the
    /// resting position at the end of the scroll changes. `verticalDrop` is added because the
    /// capsule is drawn that much lower than the frame the height was measured from.
    static func contentClearance(barHeight: CGFloat) -> CGFloat {
        max(0, barHeight) + verticalDrop + scrollClearance
    }

    static func buttonMinimumHeight(accessibilitySize: Bool) -> CGFloat {
        accessibilitySize
            ? accessibilityButtonHeight
            : max(minimumInteractiveDimension, baseButtonHeight * visualScale)
    }
}

/// Reading a finger travelling along the floating menu.
///
/// The menu is a row of equally wide buttons, so the tab under a finger is a division rather than
/// a per-button frame lookup — which also means it still works while the row is mid-animation.
enum RootTabBarSlidePolicy {
    /// Far enough that a stationary tap is never mistaken for a slide, short enough that the slide
    /// starts under the neighbouring icon rather than a whole tab later.
    static let activationDistance: CGFloat = 10

    /// A mostly-vertical drag over the menu is someone reaching past it, not sliding along it.
    static func isSlide(translation: CGSize) -> Bool {
        abs(translation.width) >= abs(translation.height)
    }

    /// The tab under a finger at `x`, clamped to the row: a finger that has run off the end is
    /// still pointing at the last tab, which is where it looks like it is pointing.
    static func tabIndex(atX x: CGFloat, stripWidth: CGFloat, count: Int) -> Int? {
        guard stripWidth > 0, count > 0 else { return nil }
        let segment = stripWidth / CGFloat(count)
        return min(count - 1, max(0, Int(x / segment)))
    }

    /// The tab a finished slide switches to, or nil for a gesture that was never a slide.
    static func committedTabIndex(
        translation: CGSize,
        x: CGFloat,
        stripWidth: CGFloat,
        count: Int
    ) -> Int? {
        guard isSlide(translation: translation) else { return nil }
        return tabIndex(atX: x, stripWidth: stripWidth, count: count)
    }

    /// What the menu draws as chosen. While a finger is travelling that is the tab beneath it, so
    /// the destination is legible before it is committed to — the selection itself, and therefore
    /// the page, does not move until the finger lifts.
    static func highlightedIndex(selection: Int, slidingTo: Int?) -> Int {
        slidingTo ?? selection
    }
}

struct RootTabBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RootTabBarClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Bottom scroll content margin the floating root menu currently needs. Zero while the menu is
    /// hidden, such as inside a conversation or a pushed Profile settings page.
    var rootTabBarClearance: CGFloat {
        get { self[RootTabBarClearanceKey.self] }
        set { self[RootTabBarClearanceKey.self] = newValue }
    }
}

private struct RootTabBarScrollClearance: ViewModifier {
    @Environment(\.rootTabBarClearance) private var clearance

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, clearance, for: .scrollContent)
    }
}

extension View {
    /// Gives a tab's scroll view enough bottom content margin to scroll its last row clear of the
    /// floating root menu, without shrinking the viewport the content is drawn in.
    ///
    /// Apply this to the scroll view at the root of each tab. Pages must not add their own bottom
    /// padding for the menu on top of it.
    func rootTabBarScrollClearance() -> some View {
        modifier(RootTabBarScrollClearance())
    }
}

private enum MainTab: Int, CaseIterable, Identifiable {
    case home
    case messages
    case calls
    case profile

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .messages: "Messages"
        case .calls: "Calls"
        case .profile: "Profile"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .messages: "message"
        case .calls: "phone"
        case .profile: "person"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: "house.fill"
        case .messages: "message.fill"
        case .calls: "phone.fill"
        case .profile: "person.fill"
        }
    }
}

private struct TabBadge {
    let count: Int
    let color: Color
    let accessibilityValue: String

    var text: String {
        count > 99 ? "99+" : String(count)
    }
}

/// What a slide across the menu is currently pointing at.
///
/// Held in `@GestureState` rather than `@State` because SwiftUI restores it on its own the moment
/// a gesture ends or is cancelled. A slide interrupted by a call banner or a system edge gesture
/// therefore cannot leave the menu parked on a tab the app never switched to.
private struct RootTabBarSlide: Equatable {
    var isActive = false
    /// `MainTab.rawValue` under the finger, or nil before the row has been measured.
    var tab: Int?
}

private struct FloatingTabBar: View {
    @Binding var selection: Int
    let unreadMessageCount: Int
    let queuedCount: Int
    /// The signed-in customer, for the Profile tab's own photo.
    let profileName: String
    let profileAvatarURL: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var tabIconSize: CGFloat = RootTabBarLayoutPolicy.iconPointSize
    @ScaledMetric(relativeTo: .caption2) private var tabCaptionSize: CGFloat = RootTabBarLayoutPolicy.captionPointSize
    @Namespace private var selectionNamespace
    @Namespace private var glassNamespace
    /// Width of the row of tab buttons, used to turn a finger position into a tab.
    @State private var stripWidth: CGFloat = 0
    @GestureState private var slide = RootTabBarSlide()

    /// What the menu is *showing* as chosen. During a slide that is the tab under the finger, so
    /// the lens travels with it and the destination is legible before committing to it; the page
    /// itself does not change until the finger lifts.
    private var highlightedTab: Int {
        RootTabBarSlidePolicy.highlightedIndex(selection: selection, slidingTo: slide.tab)
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), !reduceTransparency {
                liquidGlassBar
            } else {
                materialBar
            }
        }
        .frame(maxWidth: 620)
        .padding(
            .horizontal,
            horizontalSizeClass == .regular
                ? RootTabBarLayoutPolicy.regularHorizontalInset
                : RootTabBarLayoutPolicy.compactHorizontalInset
        )
        .padding(.top, RootTabBarLayoutPolicy.barTopPadding)
        .offset(y: RootTabBarLayoutPolicy.verticalDrop)
        // The bar lifts under a slide so the gesture reads as picking the bar up, not scrubbing it.
        .scaleEffect(slide.isActive && !reduceMotion ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: slide.isActive)
        // Every icon crossed answers under the finger, which is what makes a slide feel like it is
        // choosing rather than waiting.
        .sensoryFeedback(.selection, trigger: highlightedTab)
    }

    @available(iOS 26.0, *)
    private var liquidGlassBar: some View {
        GlassEffectContainer(spacing: 9) {
            tabStrip { tab in
                liquidGlassButton(for: tab)
            }
            .padding(RootTabBarLayoutPolicy.capsuleInset)
            // Untinted. The menu takes its colour from whatever page is passing underneath it,
            // which is the whole point of the material — a brand tint painted over the top only
            // flattens it back into a coloured bar.
            .glassEffect(.regular.interactive(!reduceMotion), in: Capsule())
            .overlay {
                barHighlight
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.14), radius: 22, y: 10)
        }
    }

    private var materialBar: some View {
        tabStrip { tab in
            materialButton(for: tab)
        }
        .padding(RootTabBarLayoutPolicy.capsuleInset)
        .background {
            if reduceTransparency {
                Capsule()
                    .fill(Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .systemBackground))
            } else {
                Capsule()
                    .fill(.thinMaterial)
                Capsule()
                    .fill(.white.opacity(colorScheme == .dark ? 0.04 : 0.18))
            }
        }
        .overlay {
            barHighlight
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.14), radius: 22, y: 10)
    }

    /// The row of tab buttons, plus the gesture that lets a finger slide from one to the next.
    ///
    /// The drag runs *alongside* the buttons rather than replacing them: a tap is still a tap on a
    /// real `Button`, with its own press feedback and accessibility, and only movement past
    /// ``RootTabBarSlidePolicy/activationDistance`` is read as a slide. While the finger travels
    /// the lens follows it and each icon crossed answers; the page changes when the finger lifts.
    private func tabStrip<Content: View>(
        @ViewBuilder button: @escaping (MainTab) -> Content
    ) -> some View {
        HStack(spacing: RootTabBarLayoutPolicy.interButtonSpacing) {
            ForEach(MainTab.allCases) { tab in
                button(tab)
            }
        }
        // The lens travels between buttons rather than cutting from one to the next. Keyed on the
        // highlight, so it animates during a slide as well as on a tap.
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.04),
            value: highlightedTab
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { stripWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in stripWidth = width }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: RootTabBarSlidePolicy.activationDistance)
                .updating($slide) { value, state, _ in
                    guard RootTabBarSlidePolicy.isSlide(translation: value.translation) else {
                        return
                    }
                    state.isActive = true
                    state.tab = tabIndex(atX: value.location.x)
                }
                .onEnded { value in
                    // The page changes on the release the moving lens promised, and only then.
                    // Switching under the finger meant every tab crossed on the way to the one
                    // being aimed at was loaded, appeared, and was thrown away again.
                    guard let index = RootTabBarSlidePolicy.committedTabIndex(
                        translation: value.translation,
                        x: value.location.x,
                        stripWidth: stripWidth,
                        count: MainTab.allCases.count
                    ), let tab = MainTab(rawValue: index) else { return }
                    select(tab, sliding: true)
                }
        )
    }

    private func tabIndex(atX x: CGFloat) -> Int? {
        RootTabBarSlidePolicy.tabIndex(
            atX: x,
            stripWidth: stripWidth,
            count: MainTab.allCases.count
        )
    }

    @available(iOS 26.0, *)
    private func liquidGlassButton(for tab: MainTab) -> some View {
        tabButton(for: tab)
            .background {
                if highlightedTab == tab.rawValue {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.035))
                        // A second, clearer lens inside the bar's own. Untinted for the same
                        // reason the bar is: the selection should read as glass lifted out of
                        // glass, not as a coloured chip laid on top of it.
                        .glassEffect(.clear.interactive(!reduceMotion), in: Capsule())
                        .glassEffectID("selected-tab", in: glassNamespace)
                        .overlay { selectionHighlight }
                        .shadow(color: .black.opacity(0.09), radius: 7, y: 3)
                }
            }
    }

    private func materialButton(for tab: MainTab) -> some View {
        tabButton(for: tab)
            .background {
                if highlightedTab == tab.rawValue {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.06))
                        .overlay { selectionHighlight }
                        .shadow(color: .black.opacity(0.08), radius: 7, y: 3)
                        .matchedGeometryEffect(id: "selected-tab", in: selectionNamespace)
                }
            }
    }

    private func tabButton(for tab: MainTab) -> some View {
        let selected = highlightedTab == tab.rawValue
        let badge = badge(for: tab)

        return Button {
            select(tab)
        } label: {
            VStack(
                spacing: dynamicTypeSize.isAccessibilitySize
                    ? 2
                    : 3 * RootTabBarLayoutPolicy.visualScale
            ) {
                ZStack(alignment: .topTrailing) {
                    tabSymbol(for: tab, selected: selected)

                    if let badge {
                        BadgeView(badge: badge)
                            .offset(x: 14, y: -7)
                    }
                }
                Text(tab.title)
                    .font(.system(
                        size: tabCaptionSize,
                        weight: selected ? .bold : .semibold,
                        design: .default
                    ))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.78)
            }
            .foregroundStyle(selected ? selectedForeground : Color.primary.opacity(0.82))
            .frame(maxWidth: .infinity)
            .frame(
                minHeight: RootTabBarLayoutPolicy.buttonMinimumHeight(
                    accessibilitySize: dynamicTypeSize.isAccessibilitySize
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue(for: tab, badge: badge, selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The Profile tab shows the customer's own photo rather than a generic silhouette — the same
    /// face they see on their profile, chats and calls, drawn from the same local cache so it is
    /// there in the first frame and offline.
    @ViewBuilder
    private func tabSymbol(for tab: MainTab, selected: Bool) -> some View {
        if tab == .profile {
            RemoteAvatarView(
                name: profileName,
                avatarURL: profileAvatarURL,
                size: tabIconSize + 4,
                ringOpacity: nil
            )
            .overlay {
                Circle()
                    .stroke(
                        Color.primary.opacity(selected ? 0.55 : 0.22),
                        lineWidth: selected ? 1.6 : 1
                    )
                    .allowsHitTesting(false)
            }
            .frame(minWidth: 32, minHeight: 26)
            .accessibilityHidden(true)
        } else {
            Image(systemName: selected ? tab.selectedIcon : tab.icon)
                .font(.system(size: tabIconSize, weight: selected ? .semibold : .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(minWidth: 32, minHeight: 26)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    /// The lit top edge and shaded underside that make a pane of glass look like one. Neutral
    /// black and white only — a tinted rim is what makes glass look painted.
    private var barHighlight: some View {
        Capsule()
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(colorScheme == .dark ? 0.42 : 0.88),
                        .white.opacity(0.10),
                        .black.opacity(colorScheme == .dark ? 0.24 : 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.9
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var selectionHighlight: some View {
        Capsule()
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0.68), .white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.8
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Contrast against whatever is passing behind the glass, not a brand colour: the selected tab
    /// is marked out by its own lens and by weight, so the label only has to be legible.
    private var selectedForeground: Color {
        colorScheme == .dark ? .white : .primary
    }

    private func badge(for tab: MainTab) -> TabBadge? {
        switch tab {
        case .home where queuedCount > 0:
            TabBadge(
                count: queuedCount,
                color: .orange,
                accessibilityValue: "\(queuedCount) queued \(queuedCount == 1 ? "item" : "items")"
            )
        case .messages where unreadMessageCount > 0:
            // The one thing on the bar that is deliberately not glass. A count nobody can pick out
            // is not a count; this is the colour iOS itself uses for an unread badge.
            TabBadge(
                count: unreadMessageCount,
                color: .red,
                accessibilityValue: "\(unreadMessageCount) unread \(unreadMessageCount == 1 ? "message" : "messages")"
            )
        default:
            nil
        }
    }

    private func accessibilityValue(for tab: MainTab, badge: TabBadge?, selected: Bool) -> String {
        [selected ? "Selected" : nil, badge?.accessibilityValue]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// A slide crosses several tabs in one gesture, so it gets a shorter, bounce-free spring: the
    /// tap animation's settle would still be running when the finger reaches the next icon.
    private func select(_ tab: MainTab, sliding: Bool = false) {
        guard selection != tab.rawValue else { return }
        if reduceMotion {
            selection = tab.rawValue
        } else if sliding {
            withAnimation(.snappy(duration: 0.20)) {
                selection = tab.rawValue
            }
        } else {
            withAnimation(.snappy(duration: 0.34, extraBounce: 0.05)) {
                selection = tab.rawValue
            }
        }
    }
}

private struct BadgeView: View {
    let badge: TabBadge

    var body: some View {
        Text(badge.text)
            .font(.system(size: 9.9, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, badge.count > 9 ? 4.5 : 0)
            .frame(minWidth: 17.1, minHeight: 17.1)
            .background(badge.color, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.82), lineWidth: 1.26)
                    .allowsHitTesting(false)
            }
            .shadow(color: badge.color.opacity(0.30), radius: 4, y: 2)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
