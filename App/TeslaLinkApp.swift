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
            model.scenePhaseChanged(active: phase == .active)
        }
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) {
            await model.handleBackgroundRefresh()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab = "car"

    var body: some View {
        Group {
            if model.isSignedIn && sizeClass == .regular {
                SidebarRoot()
            } else if model.isSignedIn {
                // Bottom tabs on iPhone; on iPad this becomes a sidebar.
                TabView(selection: $tab) {
                    Tab("Car", systemImage: "car.side.fill", value: "car") { NavigationStack { DashboardView() } }
                    Tab("Drives", systemImage: "road.lanes", value: "drives") { NavigationStack { DrivesView() } }
                    Tab("Charging", systemImage: "bolt.car.fill", value: "charges") { NavigationStack { ChargesView() } }
                    Tab("Insights", systemImage: "chart.xyaxis.line", value: "stats") { NavigationStack { StatsView() } }
                    Tab("Settings", systemImage: "gearshape", value: "settings") { NavigationStack { SettingsView() } }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tint(TL.Palette.ion)
            } else {
                NavigationStack { OnboardingView() }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
