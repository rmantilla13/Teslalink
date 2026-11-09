import SwiftUI
import TeslaLinkCore

@main
struct TeslaLinkApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() { Appearance.apply() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Inactive still means on screen (a system alert, Control Center): keep the data live.
            model.scenePhaseChanged(active: phase != .background)
        }
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) {
            await model.handleBackgroundRefresh()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab = DebugLaunch.section ?? .car

    var body: some View {
        Group {
            if model.isSignedIn && sizeClass == .regular {
                SidebarRoot()
            } else if model.isSignedIn {
                PhoneRoot(tab: $tab)
            } else {
                NavigationStack { OnboardingView() }
            }
        }
        .tint(TL.Palette.ion)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Compact width (iPhone, the Duo's outer screen): one navigation stack per section under the
/// flat steel tab bar. A section's stack is created on first visit and kept, so each tab keeps
/// its place (scroll position, pushed drive) like a system tab bar would.
struct PhoneRoot: View {
    @Binding var tab: AppSection
    @State private var visited: Set<AppSection> = []

    var body: some View {
        ZStack {
            ForEach(AppSection.allCases) { section in
                if visited.contains(section) || section == tab {
                    NavigationStack { section.rootView }
                        .opacity(section == tab ? 1 : 0)
                        .allowsHitTesting(section == tab)
                        .accessibilityHidden(section != tab)
                        .environment(\.tabIsActive, section == tab)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { TLTabBar(selection: $tab) }
        .onChange(of: tab, initial: true) { _, t in visited.insert(t) }
    }
}
