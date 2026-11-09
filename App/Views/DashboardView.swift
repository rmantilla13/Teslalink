import MapKit
import SwiftUI
import TeslaLinkCore

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var refreshing = false

    var body: some View {
        let vehicle = model.selectedVehicle
        let live = vehicle.map { model.status(for: $0.vin) } ?? LiveStatus()
        let s = live.snapshot
        let f = Fmt(model.settings.units)

        ScrollView {
            VStack(spacing: TL.Space.s6) {
                VehicleHeroView(vehicle: vehicle, snapshot: s, units: model.settings.units)

                if live.state == .charging, let vin = vehicle?.vin {
                    NavigationLink { LiveChargeView(vin: vin) } label: {
                        HStack { StateBanner(live: live); Image(systemName: "chevron.right").foregroundStyle(TL.Palette.inkMuted) }
                    }
                    .buttonStyle(.plain)
                } else {
                    StateBanner(live: live)
                }

                // Adapts: one column on iPhone, two side by side on iPad / landscape.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: TL.Space.s6) { batteryCard(s, f); climateCard(s, f) }
                        .frame(minWidth: 700)
                    VStack(spacing: TL.Space.s6) { batteryCard(s, f); climateCard(s, f) }
                }

                if s?.chargingState?.isActive == true { chargingCard(s!, f) }

                if let lat = s?.latitude, let lon = s?.longitude {
                    Card(title: "Location", symbol: "mappin.and.ellipse") {
                        Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                                                        latitudinalMeters: 800, longitudinalMeters: 800))) {
                            Annotation(vehicle?.displayName ?? "Car", coordinate: .init(latitude: lat, longitude: lon)) {
                                Image(systemName: "car.fill").padding(7).background(TL.Palette.ion, in: Circle()).foregroundStyle(TL.Palette.onIon).tlGlow()
                                    .rotationEffect(.degrees((s?.heading ?? 0) - 90))
                            }
                        }
                        .frame(height: 200)
                        .clipShape(ChamferedRectangle(cut: TL.Chamfer.sm))
                        .id("\(lat),\(lon)")
                    }
                }

                if let v = s?.softwareVersion {
                    Text("Software \(v)").font(TL.Typeface.dataSmall).foregroundStyle(TL.Palette.inkMuted)
                }
            }
            .padding(TL.Space.s4)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(TL.Palette.ground)
        .navigationTitle(vehicle?.displayName ?? "TeslaLink")
        .toolbar {
            if model.isDemo {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("Demo").tlLabel().foregroundStyle(TL.Palette.amber)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(ChamferedRectangle(cut: 4).fill(TL.Palette.amber.opacity(0.14)))
                        .accessibilityLabel("Demo mode")
                }
            }
            if model.vehicles.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(model.vehicles) { v in
                            Button(v.displayName) { model.settings.selectedVIN = v.vin }
                        }
                    } label: { Label("Vehicle", systemImage: "car.2") }
                }
            }
        }
        .refreshable {
            // Pull to refresh: one fresh read (may wake the car briefly).
            await model.pollAll(force: true)
        }
    }

    private func batteryCard(_ s: VehicleSnapshot?, _ f: Fmt) -> some View {
        Card(title: "Battery", symbol: "battery.75percent", hero: true) {
            BatteryBar(level: s?.batteryLevel, limit: s?.chargeLimitSoc, charging: s?.chargingState?.isActive == true)
            HStack(alignment: .top, spacing: TL.Space.s6) {
                Metric(label: "Rated range", value: f.distance(s?.ratedRangeKm, digits: 0))
                Metric(label: "Estimated", value: f.distance(s?.estimatedRangeKm, digits: 0))
                Metric(label: "Odometer", value: f.distance(s?.odometerKm, digits: 0))
            }
        }
    }

    private func climateCard(_ s: VehicleSnapshot?, _ f: Fmt) -> some View {
        Card(title: "Climate & security", symbol: "thermometer.medium") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Metric(label: "Inside", value: f.temperature(s?.insideTempC)); Metric(label: "Outside", value: f.temperature(s?.outsideTempC)) }
                GridRow { Metric(label: "Climate", value: s?.isClimateOn == true ? "On" : "Off")
                          Metric(label: "Sentry", value: s?.sentryMode == true ? "On" : "Off", tone: s?.sentryMode == true ? TL.Palette.amber : TL.Palette.ink) }
                GridRow { Metric(label: "Locked", value: s?.locked == false ? "No" : "Yes", tone: s?.locked == false ? TL.Palette.taillight : TL.Palette.ink)
                          Metric(label: "Windows", value: s?.windowsOpen == true ? "Open" : "Closed") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chargingCard(_ s: VehicleSnapshot, _ f: Fmt) -> some View {
        Card(title: "Charging", symbol: "bolt.fill") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Metric(label: "Power", value: f.power(s.chargerPowerKw), tone: TL.Palette.charge); Metric(label: "Added", value: f.energy(s.chargeEnergyAddedKwh), tone: TL.Palette.charge) }
                GridRow { Metric(label: "Voltage", value: s.chargerVoltage.map { "\(Int($0)) V" } ?? "–")
                          Metric(label: "Current", value: s.chargerActualCurrent.map { "\(Int($0)) A" } ?? "–") }
                GridRow { Metric(label: "Time to limit", value: f.duration(minutes: s.minutesToFullCharge.map(Double.init)))
                          Metric(label: "Type", value: s.fastChargerPresent == true ? (s.fastChargerType ?? "DC") : "AC") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
