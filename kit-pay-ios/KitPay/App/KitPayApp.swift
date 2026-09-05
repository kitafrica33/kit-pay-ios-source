import SwiftUI

@main
struct KitPayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    @StateObject private var callMedia = CallMediaCoordinator.shared
    @State private var isCallPresented = false

    init() {
        // Camera/editor outputs are plaintext only while being reviewed or staged. A crash can
        // bypass their normal owner cleanup, so retire those narrowly prefixed scratch folders
        // before any new capture session can reuse the process.
        KitCaptureTemporaryFileStore.removeAbandonedFiles()
    }

    /// The floating call surface lives in its own window rather than a `RootView` overlay, so it
    /// stays on screen above sheets, full-screen covers, and every tab, and so Picture in Picture
    /// has a stable source view to hand off from when the user leaves Kit Pay.
    private var hasPresentableCall: Bool {
        callMedia.activeCall != nil && !model.communicationSurfacesConcealed
    }

    private var showsMinimizedCall: Bool {
        hasPresentableCall && !isCallPresented
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(KitColor.green)
                .fullScreenCover(
                    isPresented: Binding(
                        get: {
                            isCallPresented && !model.communicationSurfacesConcealed
                        },
                        set: { isCallPresented = $0 }
                    ),
                    onDismiss: {
                        appDelegate.setActiveCallPresented(false)
                    }
                ) {
                    ActiveCallView(coordinator: callMedia) {
                        isCallPresented = false
                    }
                        .environmentObject(model)
                        .interactiveDismissDisabled()
                        .onAppear {
                            appDelegate.setActiveCallPresented(true)
                        }
                }
                .onAppear {
                    VoiceNoteOverlayWindowController.shared.installNavigationHandler {
                        [weak model] conversationID, messageID in
                        _ = model?.requestConversationNavigation(
                            conversationID: conversationID,
                            messageID: messageID
                        )
                    }
                    syncMinimizedCallSurface()
#if DEBUG && APP_STORE_SCREENSHOTS
                    callMedia.installCallLayoutFixtureIfRequested()
#endif
                }
                .onChange(of: hasPresentableCall) { _, _ in syncMinimizedCallSurface() }
                .onChange(of: showsMinimizedCall) { _, _ in syncMinimizedCallSurface() }
                .onChange(of: callMedia.activeCall) { previous, current in
                    if current == nil {
                        isCallPresented = false
                    } else if !model.communicationSurfacesConcealed,
                              previous == nil || previous?.id != current?.id {
                        // A new call's minimized video tile starts from its default parking spot
                        // (bottom trailing), fully on screen; the audio strip is always static
                        // along the top edge.
                        let presenter = CallOverlayWindowController.shared.presenter
                        presenter.videoTilePosition = nil
                        presenter.videoTileTuckedEdge = nil
                        isCallPresented = true
                    }
                    syncMinimizedCallSurface()
                }
                .onChange(of: model.communicationSurfacesConcealed) { _, concealed in
                    if concealed { isCallPresented = false }
                    syncMinimizedCallSurface()
                }
                .onOpenURL { url in
                    // Retain the no-payload share route for pre-picker development builds. The
                    // shipping share extension does not try to launch its containing app.
                    if KitShareHandoffLink.matches(url) {
                        model.refreshSharedInbox()
                    } else {
                        model.handleDeepLink(url)
                    }
                }
                .task { await model.requestContactsPermissionAtLaunch() }
                // A cold launch reaches `.active` before the session has been restored, so the
                // first look for a staged share finds a signed-out app. This is the moment it
                // becomes answerable.
                .onChange(of: sharedInboxReadiness) { _, _ in model.refreshSharedInbox() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.requestContactsPermissionAtLaunch() }
                        Task { await model.applicationDidBecomeActiveSecurely() }
                        // A transient `.inactive` (Control Center, system alert) may have
                        // started Picture in Picture; the app is visibly foreground again, so
                        // hand the video back to the in-app surfaces.
                        CallOverlayWindowController.shared
                            .stopPictureInPictureForForegroundIfNeeded()
                        // Same for a chat video: if the viewer it came from is still on screen,
                        // playback belongs back inside it rather than in a floating window over
                        // the app the user has just returned to.
                        ChatVideoPictureInPicture.shared.stopForForegroundIfNeeded()
                        // A share may have been staged while Kit Pay was in the background. Share
                        // extensions cannot launch their containing app, so every foreground is
                        // the reliable hand-off point.
                        model.refreshSharedInbox()
                        syncMinimizedCallSurface()
                    } else if phase == .inactive {
                        // Close authenticated signalling as soon as the app is no longer active.
                        // Waiting for `.background` leaks a live socket while Control Center,
                        // permission prompts, or the app switcher obscure the protected UI.
                        KitPresenceCenter.shared.setForeground(false)
                        // Clear any prior foreground-stop intent before AVKit can begin an
                        // automatic chat-video handoff for this deactivation.
                        ChatVideoPictureInPicture.shared.prepareForBackgrounding()
                        // The foreground→background transition point: the last moment iOS allows
                        // a programmatic Picture in Picture start, so an ongoing video call keeps
                        // showing after the user leaves the app. No-op for audio calls, when
                        // Picture in Picture is impossible, or when it is already running.
                        CallOverlayWindowController.shared
                            .startPictureInPictureForBackgroundingIfNeeded()
                    } else if phase == .background {
                        model.applicationDidEnterBackgroundSecurely()
                        // Finish the coalesced diagnostic snapshot before iOS suspends the app so
                        // a force-quit/relaunch test can export the events observed so far.
                        LocalMediaPerformanceMonitor.shared.flushPendingPersistence()
                        ContactBackgroundRefreshScheduler.shared.schedule()
                        model.scheduleAutomaticMessageBackupRefresh()
                    }
                }
        }
    }

    /// Everything that decides whether a staged share can be offered a chat yet.
    private var sharedInboxReadiness: String {
        [
            String(model.isSignedIn),
            String(model.isOnline),
            String(model.requiresBiometricSignIn),
            String(model.accountSetupStep == nil),
        ].joined(separator: ":")
    }

    @MainActor
    private func syncMinimizedCallSurface() {
        CallOverlayWindowController.shared.update(
            hasActiveCall: hasPresentableCall,
            showsMinimizedSurface: showsMinimizedCall
        ) {
            isCallPresented = true
        }
    }
}
