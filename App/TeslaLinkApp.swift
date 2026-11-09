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
    @State private var hinge: HingeState = HingeObserver.isSupported ? .unknown : .none
    @State private var geometry = PaneGeometry()
    @State private var pane = PaneSelection()

    /// Two panes split at the hinge: the Duo open in landscape. Until the hinge reports (the
    /// first frame), a wide phone screen is taken to be an open Duo, the main target.
    private var duoPanes: Bool {
        guard geometry.isLandscape else { return false }
        switch hinge {
        case .open: return true
        case .unknown: return UIDevice.current.userInterfaceIdiom == .phone && geometry.size.width > 800
        case .none, .closed: return false
        }
    }

    /// Where the open Duo's menu goes: the side column the system keeps for the clock and
    /// Wi-Fi (on the right, or the left with the Duo turned round) is free below them. nil keeps
    /// the bottom tab bar: no panes, or no column wide enough.
    private var railEdge: HorizontalEdge? {
        guard duoPanes else { return nil }
        let i = geometry.insets
        if i.trailing >= 60, i.trailing >= i.leading { return .trailing }
        if i.leading >= 60 { return .leading }
        return nil
    }

    /// The iPad layout. Never on a device with a hinge: while the Duo unfolds, its width turns
    /// regular a moment before the hinge reports open, and a sidebar there would rebuild the
    /// phone stacks (losing the tab's place). The Duo opened in portrait stays on the phone layout.
    private var sidebar: Bool {
        guard sizeClass == .regular else { return false }
        switch hinge {
        case .none: return true
        case .unknown: return UIDevice.current.userInterfaceIdiom == .pad   // an iPad has no hinge
        case .closed, .open: return false
        }
    }

    var body: some View {
        ZStack {
            if !model.isSignedIn {
                NavigationStack { OnboardingView() }
                    .environment(\.duoSplit, duoPanes ? geometry.hingeX : nil)
            } else if sidebar {
                SidebarRoot()
            } else {
                // PhoneRoot keeps its place when the Duo folds or unfolds, so the selected tab
                // and any pushed screen survive the change.
                HStack(spacing: 0) {
                    PhoneRoot(tab: $tab, showsTabBar: railEdge == nil)
                        .frame(width: duoPanes ? geometry.hingeX : nil)
                    if duoPanes {
                        Rectangle().fill(TL.Palette.edge).frame(width: 1).ignoresSafeArea()
                        CompanionPane(tab: $tab).frame(maxWidth: .infinity)
                    }
                }
                .overlay {
                    if let edge = railEdge {
                        let column = edge == .trailing ? geometry.insets.trailing : geometry.insets.leading
                        DuoRail(selection: $tab, edge: edge)
                            .frame(width: column)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .trailing ? .trailing : .leading)
                            .ignoresSafeArea()
                    }
                }
                .environment(\.paneSelection, duoPanes ? pane : nil)
            }
        }
        .onGeometryChange(for: PaneGeometry.self) { PaneGeometry(size: $0.size, insets: $0.safeAreaInsets) } action: { geometry = $0 }
        // A developer app's setup link (from the partner script, a QR code): reviewed, never
        // applied silently.
        .onOpenURL { url in
            if let link = FleetSetupLink(url: url) { model.pendingSetupLink = SetupLinkRequest(link: link) }
        }
        .fullScreenCover(item: Binding(get: { model.pendingSetupLink }, set: { model.pendingSetupLink = $0 })) { request in
            SetupLinkReview(link: request.link)
                .environment(\.duoSplit, duoPanes ? geometry.hingeX : nil)
        }
        .background(HingeObserver(state: $hinge).frame(width: 0, height: 0).accessibilityHidden(true))
        .overlay(alignment: .top) {
            if DebugLaunch.geometry { GeometryReadout(geometry: geometry, hinge: hinge) }
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
    /// False on the open Duo, where the menu sits in the side column instead. The inset stays
    /// in place either way, so folding never rebuilds the stacks (and their pushed screens).
    var showsTabBar = true
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsTabBar { TLTabBar(selection: $tab) }
        }
        .onChange(of: tab, initial: true) { _, t in visited.insert(t) }
    }
}
