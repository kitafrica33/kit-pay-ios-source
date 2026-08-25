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
            center.setForeground(
                UIApplication.shared.applicationState == .active
                    && !model.requiresBiometricSignIn
            )
            guard !Task.isCancelled else { return }
            guard model.isSignedIn,
                  model.accountSetupStep == nil,
                  model.sessionAssurance?.grantsFullAccess == true,
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
            String(model.sessionAssurance?.grantsFullAccess == true),
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
                    queuedCount: model.queuedCount
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
                    "Kit Pay will keep this account's local data hidden until support confirms "
                        + "whether the interrupted deletion request was accepted. Do not submit it again."
                )
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)

                if let supportURL = AccountDeletionContract.trustedFallbackURL {
                    Link(destination: supportURL) {
                        Label("Account deletion support", systemImage: "arrow.up.right.square")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 17))
                    .tint(KitColor.green)
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
                            + "It remains hidden; contact support before signing in again."
                        : "Unlock this device and try again. Kit Pay will not show or change local "
                            + "account data until its protected storage is available."
                )
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)

                if model.protectedLocalStateRecoveryRequiresSupport,
                   let supportURL = URL(string: "mailto:info@kit.africa") {
                    Link(destination: supportURL) {
                        Label("Contact support", systemImage: "arrow.up.right.square")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 17))
                    .tint(KitColor.green)
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

                if let supportURL = AccountDeletionContract.trustedFallbackURL {
                    Link(destination: supportURL) {
                        Label("Account deletion support", systemImage: "arrow.up.right.square")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 17))
                }
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
    static let baseButtonHeight: CGFloat = 56
    static let accessibilityButtonHeight: CGFloat = 72

    /// Matched to the system tab bar rather than to the caption underneath it: a 21pt symbol next
    /// to an 11pt label is the proportion iOS itself uses, and it stays legible at arm's length.
    static let iconPointSize: CGFloat = 21
    static let captionPointSize: CGFloat = 11

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
    static let barTopPadding: CGFloat = 7 * visualScale

    /// Extra bottom padding a page inside a tab should add for the floating menu: none. The
    /// clearance is delivered as scroll content margin through `rootTabBarScrollClearance()`;
    /// page-level padding on top of that stacks and reads as the list ending early.
    static let pageBottomPadding: CGFloat = 0

    /// Height assumed for the bar before its first measurement, so a page's very first frame is
    /// already inset instead of momentarily scrolling under the capsule. Button height plus the
    /// capsule's own inset on both edges plus `barTopPadding`.
    static let estimatedBarHeight: CGFloat = 76

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

private struct FloatingTabBar: View {
    @Binding var selection: Int
    let unreadMessageCount: Int
    let queuedCount: Int

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
    @State private var isSliding = false

    var body: some View {
        Group {
            if #available(iOS 26.0, *), !reduceTransparency {
                liquidGlassBar
            } else {
                materialBar
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 12)
        .padding(.top, RootTabBarLayoutPolicy.barTopPadding)
        .offset(y: RootTabBarLayoutPolicy.verticalDrop)
        // The bar lifts under a slide so the gesture reads as picking the bar up, not scrubbing it.
        .scaleEffect(isSliding && !reduceMotion ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: isSliding)
        .sensoryFeedback(.selection, trigger: selection)
    }

    @available(iOS 26.0, *)
    private var liquidGlassBar: some View {
        GlassEffectContainer(spacing: 9) {
            tabStrip { tab in
                liquidGlassButton(for: tab)
            }
            .padding(5 * RootTabBarLayoutPolicy.visualScale)
            .glassEffect(
                .regular
                    .tint(.white.opacity(colorScheme == .dark ? 0.04 : 0.13))
                    .interactive(!reduceMotion),
                in: Capsule()
            )
            .overlay {
                barHighlight
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.14), radius: 22, y: 10)
            .shadow(color: KitColor.green.opacity(0.08), radius: 12, y: 3)
        }
    }

    private var materialBar: some View {
        tabStrip { tab in
            materialButton(for: tab)
        }
        .padding(5 * RootTabBarLayoutPolicy.visualScale)
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
        .shadow(color: KitColor.green.opacity(0.08), radius: 12, y: 3)
    }

    /// The row of tab buttons, plus the gesture that lets a finger slide from one to the next.
    ///
    /// The drag runs *alongside* the buttons rather than replacing them: a tap is still a tap on a
    /// real `Button`, with its own press feedback and accessibility, and only movement past
    /// `slideActivationDistance` is read as a slide. The buttons share the row equally, so the tab
    /// under the finger is a division rather than a per-button frame lookup.
    private func tabStrip<Content: View>(
        @ViewBuilder button: @escaping (MainTab) -> Content
    ) -> some View {
        HStack(spacing: 3 * RootTabBarLayoutPolicy.visualScale) {
            ForEach(MainTab.allCases) { tab in
                button(tab)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { stripWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in stripWidth = width }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: Self.slideActivationDistance)
                .onChanged { value in
                    // A mostly-vertical drag over the bar is someone reaching past it, not sliding.
                    guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                    isSliding = true
                    guard let tab = tab(atX: value.location.x) else { return }
                    select(tab, sliding: true)
                }
                .onEnded { _ in isSliding = false }
        )
    }

    /// Far enough that a stationary tap is never mistaken for a slide, short enough that the slide
    /// starts under the neighbouring icon rather than a whole tab later.
    private static let slideActivationDistance: CGFloat = 10

    private func tab(atX x: CGFloat) -> MainTab? {
        let tabs = MainTab.allCases
        guard stripWidth > 0, !tabs.isEmpty else { return nil }
        let segment = stripWidth / CGFloat(tabs.count)
        let index = min(tabs.count - 1, max(0, Int(x / segment)))
        return tabs[index]
    }

    @available(iOS 26.0, *)
    private func liquidGlassButton(for tab: MainTab) -> some View {
        tabButton(for: tab)
            .background {
                if selection == tab.rawValue {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.035))
                        .glassEffect(
                            .clear
                                .tint(KitColor.green.opacity(colorScheme == .dark ? 0.13 : 0.09))
                                .interactive(!reduceMotion),
                            in: Capsule()
                        )
                        .glassEffectID("selected-tab", in: glassNamespace)
                        .overlay { selectionHighlight }
                        .shadow(color: .black.opacity(0.09), radius: 7, y: 3)
                }
            }
    }

    private func materialButton(for tab: MainTab) -> some View {
        tabButton(for: tab)
            .background {
                if selection == tab.rawValue {
                    Capsule()
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.11)
                                : KitColor.navy.opacity(0.065)
                        )
                        .overlay { selectionHighlight }
                        .shadow(color: .black.opacity(0.08), radius: 7, y: 3)
                        .matchedGeometryEffect(id: "selected-tab", in: selectionNamespace)
                }
            }
    }

    private func tabButton(for tab: MainTab) -> some View {
        let selected = selection == tab.rawValue
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
                    Image(systemName: selected ? tab.selectedIcon : tab.icon)
                        .font(.system(size: tabIconSize, weight: selected ? .semibold : .regular))
                        .symbolRenderingMode(.hierarchical)
                        .frame(minWidth: 32, minHeight: 26)
                        .contentTransition(.symbolEffect(.replace))

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

    private var barHighlight: some View {
        Capsule()
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(colorScheme == .dark ? 0.42 : 0.88),
                        .white.opacity(0.10),
                        KitColor.navy.opacity(colorScheme == .dark ? 0.28 : 0.10)
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

    private var selectedForeground: Color {
        colorScheme == .dark ? .white : KitColor.navy
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
            TabBadge(
                count: unreadMessageCount,
                color: KitColor.green,
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
