import SwiftUI
import TeslaLinkCore

/// iPad (regular width) layout: a steel sidebar with the mark, sections and the user's cars.
struct SidebarRoot: View {
    @Environment(AppModel.self) private var model
    @State private var section: AppSection? = DebugLaunch.section ?? .car

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: TL.Space.s8) {
                HStack(spacing: TL.Space.s2) {
                    TeslaLinkMark().frame(width: 42)
                    Text("TeslaLink").font(TL.Typeface.display(20)).foregroundStyle(TL.Palette.ink)
                }
                .padding(.horizontal, TL.Space.s2)

                VStack(spacing: 2) {
                    ForEach(AppSection.allCases) { s in
                        SidebarRow(title: s.title, symbol: s.symbol, selected: section == s) { section = s }
                    }
                }

                if !model.vehicles.isEmpty {
                    VStack(alignment: .leading, spacing: TL.Space.s1) {
                        Text("Vehicles").tlLabel().padding(.horizontal, TL.Space.s3)
                        ForEach(model.vehicles) { v in
                            let state = model.status(for: v.vin).state
                            Button {
                                model.settings.selectedVIN = v.vin
                            } label: {
                                HStack {
                                    Text(v.displayName)
                                        .font(TL.Typeface.sans(15, .semibold))
                                        .foregroundStyle(v.vin == model.selectedVehicle?.vin ? TL.Palette.ink : TL.Palette.inkMuted)
                                    Spacer()
                                    Circle().fill(state.color).frame(width: 8, height: 8)
                                        .shadow(color: state == .charging || state == .driving ? state.color.opacity(0.7) : .clear, radius: 5)
                                }
                                .padding(.vertical, 10).padding(.horizontal, TL.Space.s3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(v.displayName), \(state.label)")
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, TL.Space.s8)
            .padding(.horizontal, TL.Space.s4)
            .background(TL.Palette.surface1.opacity(0.6))
            .navigationSplitViewColumnWidth(260)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            NavigationStack { (section ?? .car).rootView }
        }
        .tint(TL.Palette.ion)
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case car, drives, charging, insights, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .car: "Car"
        case .drives: "Drives"
        case .charging: "Charging"
        case .insights: "Insights"
        case .settings: "Settings"
        }
    }

    /// Outline symbols, like the square-capped line glyphs in the design.
    var symbol: String {
        switch self {
        case .car: "car.side"
        case .drives: "road.lanes"
        case .charging: "bolt"
        case .insights: "chart.xyaxis.line"
        case .settings: "slider.horizontal.3"
        }
    }

    @MainActor @ViewBuilder var rootView: some View {
        switch self {
        case .car: DashboardView()
        case .drives: DrivesView()
        case .charging: ChargesView()
        case .insights: StatsView()
        case .settings: SettingsView()
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TL.Space.s3) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)
                    .foregroundStyle(selected ? TL.Palette.ion : TL.Palette.inkMuted)
                Text(title)
                    .font(TL.Typeface.sans(15, .semibold))
                    .foregroundStyle(selected ? TL.Palette.ink : TL.Palette.inkMuted)
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, TL.Space.s3)
            .background(selected ? TL.Palette.surface2 : Color.clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(TL.Palette.ion).frame(width: 2).padding(.vertical, 8).tlGlow(radius: 6) }
            }
            .clipShape(ChamferedRectangle(cut: TL.Chamfer.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
