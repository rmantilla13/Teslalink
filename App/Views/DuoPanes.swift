import SwiftUI
import TeslaLinkCore
import UIKit

// The iPhone Duo open: the inner screen is about 951 × 669 pt in landscape, with the hinge
// down its middle. TeslaLink splits there. The left half is the phone app (sections and the
// tab bar, as on the outer screen); the right half is a companion for the current section:
// the drive or charge picked on the left, live charging. Closed, the outer screen gets the
// phone layout unchanged.

/// Whether the device has a hinge, and whether it's open.
enum HingeState: Equatable {
    /// Not reported yet: the first frame on a device that can report a hinge.
    case unknown
    /// No hinge, or no way to read it.
    case none
    case closed
    case open
}

/// Reads the hinge with `UIHingeInteraction`, which reports the current state as soon as it
/// joins a window. The API is in the iOS 27.1 SDK (Xcode 27.1, Swift 6.4); CI's Xcode is
/// older, so the code compiles only with a new enough toolchain.
struct HingeObserver: UIViewRepresentable {
    @Binding var state: HingeState

    static var isSupported: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) { return true }
        #endif
        return false
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.isUserInteractionEnabled = false
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            let state = $state
            view.addInteraction(UIHingeInteraction { _, update in
                guard let hinge = update.hinge else {
                    state.wrappedValue = .none
                    return
                }
                switch hinge.status {
                case .partiallyOpen, .fullyOpen: state.wrappedValue = .open
                // Closed, or a hinge whose posture isn't known yet: the one-pane phone layout.
                default: state.wrappedValue = .closed
                }
            })
            // The handler gets an initial state only where there is one, so a device without a
            // hinge may never call it. The Duo answers within about 0.1 s of joining a window;
            // after half a second without an answer, there's no hinge.
            view.onWindow = {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if state.wrappedValue == .unknown { state.wrappedValue = .none }
                }
            }
        }
        #endif
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    /// Calls `onWindow` once, when it first joins a window.
    final class ProbeView: UIView {
        var onWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let onWindow else { return }
            self.onWindow = nil
            onWindow()
        }
    }
}

/// Size and safe-area insets of the app's content, for placing the split at the hinge.
struct PaneGeometry: Equatable {
    var size: CGSize = .zero
    var insets = EdgeInsets()

    /// The hinge's x in content coordinates: half the full screen width, less the leading
    /// inset. There's no fold-geometry API; the Duo's inner hinge is centred.
    var hingeX: CGFloat { max(0, (insets.leading + size.width + insets.trailing) / 2 - insets.leading) }

    var isLandscape: Bool { size.width > size.height }
}

/// What the open Duo's right pane shows, picked from the list on the left.
@MainActor
@Observable
final class PaneSelection {
    var drive: Drive?
    var charge: ChargeSession?
    /// Show the running session (Live charging) rather than a finished one.
    var liveCharge = false
    /// Insights' period, shared by its two halves.
    var insightsPeriod: StatsView.Period = .month
}

extension EnvironmentValues {
    /// Set while the open Duo shows two panes: lists select into the right pane instead of pushing.
    @Entry var paneSelection: PaneSelection?
}

/// The right half of the open Duo: a companion for the section on the left.
struct CompanionPane: View {
    @Binding var tab: AppSection
    @Environment(AppModel.self) private var model
    @Environment(\.paneSelection) private var pane

    var body: some View {
        Group {
            switch tab {
            case .car:
                if let vin = model.selectedVehicle?.vin, model.status(for: vin).state == .charging {
                    NavigationStack { LiveChargeView(vin: vin, backTitle: nil) }
                } else {
                    NavigationStack { CarCompanion(tab: $tab) }
                }
            case .drives:
                if let drive = pane?.drive {
                    NavigationStack { DriveDetailView(drive: drive, backTitle: nil) }
                        .id(drive.id)
                } else {
                    PanePlaceholder(symbol: AppSection.drives.symbol, text: "Pick a drive to see its route and charts.")
                }
            case .charging:
                if pane?.liveCharge == true, let vin = model.selectedVehicle?.vin {
                    NavigationStack { LiveChargeView(vin: vin, backTitle: nil) }
                } else if let charge = pane?.charge {
                    NavigationStack { ChargeDetailView(charge: charge, backTitle: nil) }
                        .id(charge.id)
                } else {
                    PanePlaceholder(symbol: AppSection.charging.symbol, text: "Pick a charging session to see its curve and cost.")
                }
            case .insights:
                NavigationStack { StatsView(part: .details) }
            case .settings:
                NavigationStack { GeofencesView(inPane: true) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TL.Palette.ground.ignoresSafeArea())
    }
}

/// Car's companion while the car isn't charging: the week in numbers, the latest drives and
/// where the car is (iPad artboard's lower half).
struct CarCompanion: View {
    @Binding var tab: AppSection
    @Environment(AppModel.self) private var model
    @Environment(\.paneSelection) private var pane
    @State private var drives: [Drive] = []
    @State private var charges: [ChargeSession] = []
    @State private var fences: [RecordID: String] = [:]

    var body: some View {
        let f = Fmt(model.settings.units)
        let vehicle = model.selectedVehicle
        let snapshot = vehicle.flatMap { model.status(for: $0.vin).snapshot }
        let weekStart = Date().addingTimeInterval(-7 * 86_400)
        let week = PeriodStats(drives: drives.filter { !$0.isOpen && $0.startDate >= weekStart },
                               charges: charges.filter { !$0.isOpen && $0.startDate >= weekStart })
        let health = DegradationEstimator.healthPercent(DegradationEstimator.series(charges: charges, efficiencyKwhPerKm: vehicle?.efficiencyKwhPerKm))

        ScrollView {
            VStack(spacing: TL.Space.s4) {
                ScreenHeader(label: "Last 7 days", title: "This week")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: TL.Space.s3), GridItem(.flexible(), spacing: TL.Space.s3)], spacing: TL.Space.s3) {
                    StatTile(title: "Distance", value: f.distance(week.distanceKm, digits: 0))
                    StatTile(title: "Efficiency", value: f.efficiency(whPerKm: week.efficiencyWhPerKm), tone: TL.Palette.charge)
                    StatTile(title: "Charged", value: f.energy(week.energyAddedKwh))
                    StatTile(title: "Battery health", value: health.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "–")
                }
                if !drives.isEmpty {
                    Card(title: "Recent drives", lightbar: false, aside: AnyView(
                        Button("See all") { tab = .drives }
                            .font(TL.Typeface.sans(14, .semibold))
                            .foregroundStyle(TL.Palette.ion)
                            .buttonStyle(.plain))) {
                        RowGroup {
                            ForEach(drives.prefix(3)) { d in
                                Button {
                                    pane?.drive = d
                                    tab = .drives
                                } label: {
                                    DriveRow(drive: d, fences: fences, f: f).tlRow()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if let snapshot, snapshot.latitude != nil {
                    CarLocationCard(name: vehicle?.displayName, snapshot: snapshot, height: 180)
                }
            }
            .padding(.horizontal, TL.Space.s4)
            .padding(.bottom, TL.Space.s6)
        }
        .tlScreen()
        .task(id: model.dataVersion) { await load() }
    }

    private func load() async {
        guard let vin = model.selectedVehicle?.vin else { return }
        drives = (try? await model.store.drives(vin: vin, limit: 60)) ?? []
        charges = (try? await model.store.charges(vin: vin)) ?? []
        fences = Dictionary(uniqueKeysWithValues: ((try? await model.store.geofences()) ?? []).compactMap { g in g.id.map { ($0, g.name) } })
    }
}

/// The open Duo's menu, down the side column the system keeps for the clock and Wi-Fi. The
/// sections sit centred in the free height below them, lit like the tab bar's. The hairline
/// and the selection bar face the content.
struct DuoRail: View {
    @Binding var selection: AppSection
    let edge: HorizontalEdge
    /// Clears the clock and Wi-Fi at the top of the column (about 100 pt on the Duo).
    var statusHeight: CGFloat = 112

    var body: some View {
        let inner: Alignment = edge == .trailing ? .leading : .trailing
        VStack(spacing: TL.Space.s2) {
            ForEach(AppSection.allCases) { section in
                let on = section == selection
                Button { selection = section } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 19, weight: .semibold))
                            .frame(height: 24)
                        Text(section.title)
                            .font(TL.Typeface.sans(10, .semibold))
                            .tracking(0.4)
                    }
                    .foregroundStyle(on ? TL.Palette.ion : TL.Palette.inkMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(on ? TL.Palette.surface1 : Color.clear)
                    .overlay(alignment: inner) {
                        if on {
                            Rectangle().fill(TL.Palette.ion)
                                .frame(width: 2)
                                .padding(.vertical, 12)
                                .tlGlow(radius: 6)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, statusHeight)
        .padding(.bottom, 34)
        .background(alignment: inner) { Rectangle().fill(TL.Palette.edge).frame(width: 1) }
        .background(TL.Palette.ground)
    }
}

/// Shown in the right pane when there's nothing to show yet.
struct PanePlaceholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: TL.Space.s3) {
            Image(systemName: symbol).font(.system(size: 28, weight: .semibold)).foregroundStyle(TL.Palette.steelDeep)
            Text(text).font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted).multilineTextAlignment(.center)
        }
        .padding(TL.Space.s8)
    }
}

/// Debug overlay (`-TLGeometry YES`): content size, safe-area insets, hinge and idiom.
struct GeometryReadout: View {
    let geometry: PaneGeometry
    let hinge: HingeState

    var body: some View {
        let i = geometry.insets
        let idiom = UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "pad"
        Text("\(Int(geometry.size.width))×\(Int(geometry.size.height))  L\(Int(i.leading)) T\(Int(i.top)) R\(Int(i.trailing)) B\(Int(i.bottom))  hinge \(String(describing: hinge)) x\(Int(geometry.hingeX))  \(idiom)")
            .font(TL.Typeface.mono(10))
            .foregroundStyle(.black)
            .padding(4)
            .background(Color.yellow)
            .allowsHitTesting(false)
    }
}
