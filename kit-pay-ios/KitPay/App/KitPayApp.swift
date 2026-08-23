import SwiftUI

@main
struct KitPayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    @StateObject private var callMedia = CallMediaCoordinator.shared
    @State private var isCallPresented = false

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
                .onAppear { syncMinimizedCallSurface() }
                .onChange(of: hasPresentableCall) { _, _ in syncMinimizedCallSurface() }
                .onChange(of: showsMinimizedCall) { _, _ in syncMinimizedCallSurface() }
                .onChange(of: callMedia.activeCall) { previous, current in
                    if current == nil {
                        isCallPresented = false
                    } else if !model.communicationSurfacesConcealed,
                              previous == nil || previous?.id != current?.id {
                        // A video call parks where a picture-in-picture window belongs; an audio
                        // call parks along the top edge, where a call banner is expected.
                        CallOverlayWindowController.shared.presenter.corner =
                            current?.video == true ? .bottomTrailing : .topCenter
                        isCallPresented = true
                    }
                    syncMinimizedCallSurface()
                }
                .onChange(of: model.communicationSurfacesConcealed) { _, concealed in
                    if concealed { isCallPresented = false }
                    syncMinimizedCallSurface()
                }
                .onOpenURL { model.handleDeepLink($0) }
                .task { await model.requestContactsPermissionAtLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.requestContactsPermissionAtLaunch() }
                        Task { await model.applicationDidBecomeActiveSecurely() }
                        syncMinimizedCallSurface()
                    } else if phase == .background {
                        model.applicationDidEnterBackgroundSecurely()
                        ContactBackgroundRefreshScheduler.shared.schedule()
                        MessageBackupRefreshScheduler.shared.schedule()
                    }
                }
        }
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
