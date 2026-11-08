import Charts
import SwiftUI
import TeslaLinkCore

struct ChargesView: View {
    @Environment(AppModel.self) private var model
    @State private var charges: [ChargeSession] = []
    @State private var fences: [RecordID: String] = [:]

    var body: some View {
        let f = Fmt(model.settings.units)
        List {
            if charges.isEmpty {
                ContentUnavailableView("No charging sessions yet", systemImage: "bolt.car",
                                       description: Text("Plug in and TeslaLink will log the session, even from sparse background updates."))
            }
            ForEach(charges) { c in
                NavigationLink(value: c) {
                    HStack(spacing: 12) {
                        Image(systemName: c.isDCFast ? "bolt.circle.fill" : "powerplug.fill")
                            .font(.title2)
                            .foregroundStyle(c.isDCFast ? .orange : .green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.geofenceID.flatMap { fences[$0] } ?? c.address ?? (c.isDCFast ? "Fast charger" : "Charging"))
                                .font(.subheadline.weight(.medium))
                            Text("\(c.startDate.formatted(date: .abbreviated, time: .shortened)) · \(f.duration(minutes: c.durationMin))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("+\(f.energy(c.energyAddedKwh))").font(.subheadline.monospacedDigit())
                            Text("\(c.startBatteryLevel.map(String.init) ?? "–") → \(c.endBatteryLevel.map(String.init) ?? "–")%")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let cost = c.cost { Text(f.money(cost)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .onDelete { idx in Task { await delete(idx.map { charges[$0] }) } }
        }
        .navigationTitle("Charging")
        .navigationDestination(for: ChargeSession.self) { ChargeDetailView(charge: $0) }
        .task(id: model.dataVersion) { await load() }
    }

    private func load() async {
        guard let vin = model.selectedVehicle?.vin else { return }
        charges = (try? await model.store.charges(vin: vin, limit: 500)) ?? []
        fences = Dictionary(uniqueKeysWithValues: ((try? await model.store.geofences()) ?? []).compactMap { g in g.id.map { ($0, g.name) } })
    }

    private func delete(_ items: [ChargeSession]) async {
        for c in items { if let id = c.id { try? await model.store.deleteCharge(id: id) } }
        model.markDataChanged()
    }
}

struct ChargeDetailView: View {
    @Environment(AppModel.self) private var model
    let charge: ChargeSession
    @State private var samples: [ChargeSample] = []

    var body: some View {
        let f = Fmt(model.settings.units)
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Session", symbol: "bolt.fill") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow { Metric(label: "Energy added", value: f.energy(charge.energyAddedKwh)); Metric(label: "From the wall", value: f.energy(charge.energyUsedKwh)) }
                        GridRow { Metric(label: "Efficiency", value: charge.chargingEfficiency.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                                  Metric(label: "Cost", value: f.money(charge.cost)) }
                        GridRow { Metric(label: "Battery", value: "\(charge.startBatteryLevel.map(String.init) ?? "–")% → \(charge.endBatteryLevel.map(String.init) ?? "–")%")
                                  Metric(label: "Range added", value: f.distance(rangeAdded, digits: 0)) }
                        GridRow { Metric(label: "Duration", value: f.duration(minutes: charge.durationMin)); Metric(label: "Peak power", value: f.power(charge.powerMaxKw)) }
                        GridRow { Metric(label: "Charger", value: charge.fastChargerType ?? "AC"); Metric(label: "Outside", value: f.temperature(charge.outsideTempAvgC)) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if charge.energyUsedKwh == nil, charge.sampleCount > 0 {
                        Label("Wall energy needs frequent samples. Keep the app open while charging for a full curve.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if samples.count > 2 {
                    Card(title: "Charge curve", symbol: "chart.line.uptrend.xyaxis") {
                        Chart {
                            ForEach(samples.filter { $0.chargerPowerKw != nil }, id: \.timestamp) { s in
                                LineMark(x: .value("Time", s.timestamp), y: .value("kW", s.chargerPowerKw!), series: .value("Series", "Power"))
                                    .foregroundStyle(.orange)
                                    .interpolationMethod(.monotone)
                            }
                        }
                        .chartYAxisLabel("kW")
                        .frame(height: 180)
                    }
                    Card(title: "Power vs battery level", symbol: "battery.100percent.bolt") {
                        Chart(samples.filter { $0.chargerPowerKw != nil && $0.batteryLevel != nil }, id: \.timestamp) { s in
                            PointMark(x: .value("SoC %", s.batteryLevel!), y: .value("kW", s.chargerPowerKw!))
                                .foregroundStyle(.green)
                        }
                        .chartXScale(domain: 0...100)
                        .frame(height: 180)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(charge.startDate.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) {
            if let id = charge.id { samples = (try? await model.store.samples(sessionID: id)) ?? [] }
        }
    }

    private var rangeAdded: Double? {
        guard let a = charge.startRatedRangeKm, let b = charge.endRatedRangeKm else { return nil }
        return b - a
    }
}
