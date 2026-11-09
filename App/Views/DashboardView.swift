import MapKit
import SwiftUI
import TeslaLinkCore

/// Car: the selected vehicle at a glance (Car artboard).
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    /// Set on the open Duo, where the right pane carries live charging and the map.
    @Environment(\.paneSelection) private var pane

    var body: some View {
        let vehicle = model.selectedVehicle
        let live = vehicle.map { model.status(for: $0.vin) } ?? LiveStatus()
        let s = live.snapshot
        let f = Fmt(model.settings.units)
        let config = s?.config ?? vehicle?.config

        ScrollView {
            VStack(spacing: TL.Space.s4) {
                ScreenHeader(label: config?.headerLabel, title: Text(vehicle?.displayName ?? "TeslaLink")) {
                    HStack(spacing: TL.Space.s2) {
                        if model.isDemo { DemoBadge() }
                        if model.vehicles.count > 1 { vehicleSwitcher }
                    }
                }

                VehicleHeroView(vehicle: vehicle, snapshot: s, units: model.settings.units)

                if live.state == .charging, let vin = vehicle?.vin, pane == nil {
                    NavigationLink { LiveChargeView(vin: vin, backTitle: "Car") } label: {
                        HStack(spacing: TL.Space.s2) {
                            StateBanner(live: live)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(TL.Palette.inkMuted)
                        }
                        .contentShape(Rectangle())   // the whole row, not just the chip and text, opens it
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the live charging session")
                } else {
                    StateBanner(live: live)
                }

                // One column on iPhone; side by side when there's room (iPad, landscape).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: TL.Space.s6) { batteryCard(s, f); climateCard(s, f) }
                        .frame(minWidth: 700)
                    VStack(spacing: TL.Space.s4) { batteryCard(s, f); climateCard(s, f) }
                }

                if pane == nil, let s, s.latitude != nil {
                    CarLocationCard(name: vehicle?.displayName, snapshot: s)
                }

                if let v = s?.softwareVersion {
                    Text("Software \(v)").font(TL.Typeface.dataSmall).foregroundStyle(TL.Palette.inkMuted)
                }
            }
            .padding(.horizontal, TL.Space.s4)
            .padding(.bottom, TL.Space.s6)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .tlScreen()
        .refreshable {
            // Pull to refresh: one fresh read (may wake the car briefly).
            await model.pollAll(force: true)
        }
    }

    /// 44 pt chamfered button that picks another car (only with more than one).
    private var vehicleSwitcher: some View {
        Menu {
            ForEach(model.vehicles) { v in
                Button(v.displayName) { model.settings.selectedVIN = v.vin }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TL.Palette.inkMuted)
                .frame(width: 44, height: 44)
                .background(ChamferedRectangle(cut: TL.Chamfer.sm).fill(TL.Palette.surface2))
        }
        .accessibilityLabel("Switch vehicle")
    }

    private func batteryCard(_ s: VehicleSnapshot?, _ f: Fmt) -> some View {
        let charging = s?.chargingState?.isActive == true
        return Card(title: "Battery", hero: true) {
            BatteryBar(level: s?.batteryLevel, limit: s?.chargeLimitSoc, charging: charging, note: timeToLimit(s, f))
            Rectangle().fill(TL.Palette.edge).frame(height: 1).padding(.top, TL.Space.s1)
            HStack(alignment: .top, spacing: TL.Space.s3) {
                Metric(label: "Rated", value: f.distance(s?.ratedRangeKm, digits: 0)).frame(maxWidth: .infinity, alignment: .leading)
                Metric(label: "Estimated", value: f.distance(s?.estimatedRangeKm, digits: 0)).frame(maxWidth: .infinity, alignment: .leading)
                Metric(label: "Odometer", value: f.distance(s?.odometerKm, digits: 0)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// "80% in 1 h 05 min" while charging.
    private func timeToLimit(_ s: VehicleSnapshot?, _ f: Fmt) -> Text? {
        guard let s, s.chargingState?.isActive == true, let minutes = s.minutesToFullCharge, minutes > 0, let limit = s.chargeLimitSoc else {
            return nil
        }
        return Text("\(limit)% in ") + Text(f.duration(minutes: Double(minutes))).font(TL.Typeface.display(13, .medium)).foregroundColor(TL.Palette.ink)
    }

    private func climateCard(_ s: VehicleSnapshot?, _ f: Fmt) -> some View {
        Card(title: "") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TL.Space.s3, alignment: .leading), count: 3),
                      alignment: .leading, spacing: TL.Space.s3) {
                Metric(label: "Inside", value: f.temperature(s?.insideTempC))
                Metric(label: "Outside", value: f.temperature(s?.outsideTempC))
                Metric(label: "Climate", value: Self.word(s?.isClimateOn, yes: "On", no: "Off"))
                Metric(label: "Sentry", value: Self.word(s?.sentryMode, yes: "On", no: "Off"),
                       tone: s?.sentryMode == true ? TL.Palette.amber : TL.Palette.ink)
                Metric(label: "Locked", value: Self.word(s?.locked, yes: "Yes", no: "No"),
                       tone: s?.locked == false ? TL.Palette.taillight : TL.Palette.ink)
                Metric(label: "Windows", value: Self.word(s?.windowsOpen, yes: "Open", no: "Closed"),
                       tone: s?.windowsOpen == true ? TL.Palette.amber : TL.Palette.ink)
            }
        }
    }

    /// Missing data is an en dash, never a guess (brand book).
    static func word(_ value: Bool?, yes: String, no: String) -> String {
        value.map { $0 ? yes : no } ?? "–"
    }
}

/// Where the car is: a muted map with the car marker, heading-rotated.
struct CarLocationCard: View {
    let name: String?
    let snapshot: VehicleSnapshot
    var height: CGFloat = 200

    var body: some View {
        if let lat = snapshot.latitude, let lon = snapshot.longitude {
            Card(title: "Location") {
                Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                                                latitudinalMeters: 800, longitudinalMeters: 800))) {
                    Annotation(name ?? "Car", coordinate: .init(latitude: lat, longitude: lon)) {
                        Image(systemName: "car.fill").padding(7).background(TL.Palette.ion, in: Circle()).foregroundStyle(TL.Palette.onIon).tlGlow()
                            .rotationEffect(.degrees((snapshot.heading ?? 0) - 90))
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .frame(height: height)
                .clipShape(ChamferedRectangle(cut: TL.Chamfer.sm))
                .id("\(lat),\(lon)")
            }
        }
    }
}

struct StateBanner: View {
    let live: LiveStatus

    var body: some View {
        HStack(spacing: TL.Space.s3) {
            StateChip(state: live.state, detail: detail)
            Spacer(minLength: 0)
            Group {
                if let b = live.blocker {
                    Text("Awake: \(b.label)").foregroundStyle(TL.Palette.amber)
                } else if let e = live.lastError {
                    Text(e).foregroundStyle(TL.Palette.taillight).lineLimit(2)
                } else if let t = live.snapshot?.timestamp {
                    Text("Updated \(t, style: .relative) ago").foregroundStyle(TL.Palette.inkMuted)
                }
            }
            .font(TL.Typeface.caption)
            .multilineTextAlignment(.trailing)
        }
    }

    private var detail: String? {
        guard let s = live.snapshot else { return nil }
        switch live.state {
        case .charging: return s.chargerPowerKw.map { "\(Int($0)) kW" }
        case .updating(let v): return v
        default: return nil
        }
    }
}

extension VehicleConfig {
    /// "Model Y · Long Range" for the Car header. Unknown trim badges show the model only.
    var headerLabel: String {
        var parts = [model.displayName]
        let badge = trimBadging?.lowercased() ?? ""
        if badge.hasPrefix("p") {
            parts.append("Performance")
        } else if ["74", "75", "82", "90", "100"].contains(where: badge.hasPrefix) {
            parts.append("Long Range")
        }
        return parts.joined(separator: " · ")
    }
}
