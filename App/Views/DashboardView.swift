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
            VStack(spacing: 16) {
                VehicleHeroView(vehicle: vehicle, snapshot: s, units: model.settings.units)

                StateBanner(live: live)

                // Adapts: one column on iPhone, two side by side on iPad / landscape.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { batteryCard(s, f); climateCard(s, f) }
                        .frame(minWidth: 700)
                    VStack(spacing: 16) { batteryCard(s, f); climateCard(s, f) }
                }

                if s?.chargingState?.isActive == true { chargingCard(s!, f) }

                if let lat = s?.latitude, let lon = s?.longitude {
                    Card(title: "Location", symbol: "mappin.and.ellipse") {
                        Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                                                        latitudinalMeters: 800, longitudinalMeters: 800))) {
                            Annotation(vehicle?.displayName ?? "Car", coordinate: .init(latitude: lat, longitude: lon)) {
                                Image(systemName: "car.fill").padding(6).background(.tint, in: Circle()).foregroundStyle(.white)
                                    .rotationEffect(.degrees((s?.heading ?? 0) - 90))
                            }
                        }
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .id("\(lat),\(lon)")
                    }
                }

                if let v = s?.softwareVersion {
                    Text("Software \(v)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(vehicle?.displayName ?? "TeslaLink")
        .toolbar {
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
        Card(title: "Battery", symbol: "battery.75percent") {
            HStack(spacing: 20) {
                BatteryRing(level: s?.batteryLevel, limit: s?.chargeLimitSoc, charging: s?.chargingState?.isActive == true)
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Metric(label: "Rated range", value: f.distance(s?.ratedRangeKm, digits: 0))
                    Metric(label: "Estimated", value: f.distance(s?.estimatedRangeKm, digits: 0))
                    Metric(label: "Odometer", value: f.distance(s?.odometerKm, digits: 0))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func climateCard(_ s: VehicleSnapshot?, _ f: Fmt) -> some View {
        Card(title: "Climate & security", symbol: "thermometer.medium") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Metric(label: "Inside", value: f.temperature(s?.insideTempC)); Metric(label: "Outside", value: f.temperature(s?.outsideTempC)) }
                GridRow { Metric(label: "Climate", value: s?.isClimateOn == true ? "On" : "Off")
                          Metric(label: "Sentry", value: s?.sentryMode == true ? "On" : "Off") }
                GridRow { Metric(label: "Locked", value: s?.locked == false ? "No" : "Yes")
                          Metric(label: "Windows", value: s?.windowsOpen == true ? "Open" : "Closed") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chargingCard(_ s: VehicleSnapshot, _ f: Fmt) -> some View {
        Card(title: "Charging", symbol: "bolt.fill") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Metric(label: "Power", value: f.power(s.chargerPowerKw)); Metric(label: "Added", value: f.energy(s.chargeEnergyAddedKwh)) }
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
        HStack(spacing: 10) {
            Image(systemName: live.state.symbol)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(live.state.color, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(live.state.label).font(.headline)
                if let b = live.blocker {
                    Text("Awake: \(b.label)").font(.caption).foregroundStyle(.secondary)
                } else if let e = live.lastError {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let t = live.snapshot?.timestamp {
                    Text("Updated \(t, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium).monospacedDigit())
        }
    }
}
