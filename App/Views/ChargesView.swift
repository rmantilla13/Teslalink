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
            if let live = charges.first(where: \.isOpen), let vin = model.selectedVehicle?.vin {
                Section {
                    NavigationLink { LiveChargeView(vin: vin) } label: {
                        HStack(spacing: TL.Space.s3) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Charging now").tlLabel()
                                Text("+" + f.energy(live.energyAddedKwh))
                                    .font(TL.Typeface.display(28))
                                    .monospacedDigit()
                                    .foregroundStyle(TL.Palette.charge)
                                Text(f.power(model.status(for: vin).snapshot?.chargerPowerKw) + " · " + f.duration(minutes: live.durationMin))
                                    .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                            }
                            Spacer()
                            BatteryBar(level: model.status(for: vin).snapshot?.batteryLevel, limit: nil, charging: true, segments: 10)
                                .frame(width: 120)
                        }
                    }
                    .listRowBackground(TL.Palette.charge.opacity(0.08))
                }
            }
            if charges.isEmpty {
                ContentUnavailableView("No charging sessions yet", systemImage: "bolt.car",
                                       description: Text("Plug in and TeslaLink will log the session, even from sparse background updates."))
                    .listRowBackground(Color.clear)
            }
            ForEach(charges.filter { !$0.isOpen }) { c in
                NavigationLink(value: c) {
                    HStack(spacing: 12) {
                        Image(systemName: c.isDCFast ? "bolt.circle.fill" : "powerplug.fill")
                            .font(.title2)
                            .foregroundStyle(c.isDCFast ? TL.Palette.amber : TL.Palette.charge)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.geofenceID.flatMap { fences[$0] } ?? c.address ?? (c.isDCFast ? "Fast charger" : "Charging"))
                                .font(TL.Typeface.bodyStrong)
                            Text("\(c.startDate.formatted(date: .abbreviated, time: .shortened)) · \(f.duration(minutes: c.durationMin))")
                                .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("+\(f.energy(c.energyAddedKwh))").font(TL.Typeface.display(17, .medium)).monospacedDigit().foregroundStyle(TL.Palette.charge)
                            Text("\(c.startBatteryLevel.map(String.init) ?? "–") → \(c.endBatteryLevel.map(String.init) ?? "–")%")
                                .font(TL.Typeface.dataSmall).foregroundStyle(TL.Palette.inkMuted)
                            if let cost = c.cost { Text(f.money(cost)).font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted) }
                        }
                    }
                }
            }
            .onDelete { idx in
                let closed = charges.filter { !$0.isOpen }
                Task { await delete(idx.map { closed[$0] }) }
            }
        }
        .tlListStyle()
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
    @State private var tariff: Tariff?

    var body: some View {
        let f = Fmt(model.settings.units)
        ScrollView {
            VStack(spacing: TL.Space.s6) {
                Card(title: "Session", symbol: "bolt.fill") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow { Metric(label: "Energy added", value: f.energy(charge.energyAddedKwh), tone: TL.Palette.charge); Metric(label: "From the wall", value: f.energy(charge.energyUsedKwh)) }
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
                            .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                    }
                }

                let curve = samples.compactMap { s in s.chargerPowerKw.map { TLPoint(x: s.timestamp, y: $0) } }
                if curve.count > 2 {
                    Card(title: "Charge curve", symbol: "chart.line.uptrend.xyaxis", hero: true, aside: AnyView(ChartUnit(text: "kW"))) {
                        TLLineChart(points: curve, color: TL.Palette.charge, liveEnd: charge.isOpen,
                                    band: offPeakBand, height: 170, valueFormat: { "\(Int($0.rounded())) kW" })
                        if let peak = charge.powerMaxKw {
                            ChartNote(text: "Peak \(Int(peak.rounded())) kW\(charge.isDCFast ? ". Power tapers as the battery fills." : ".")")
                        }
                    }
                    let bySoc = samples.filter { $0.chargerPowerKw != nil && $0.batteryLevel != nil }
                    if bySoc.count > 2 {
                        Card(title: "Power vs battery level", symbol: "battery.100percent.bolt", lightbar: false, aside: AnyView(ChartUnit(text: "kW · %"))) {
                            Chart(bySoc, id: \.timestamp) { s in
                                PointMark(x: .value("Battery", s.batteryLevel!), y: .value("kW", s.chargerPowerKw!))
                                    .symbolSize(30)
                                    .foregroundStyle(TL.Palette.ion.opacity(0.3))
                                PointMark(x: .value("Battery", s.batteryLevel!), y: .value("kW", s.chargerPowerKw!))
                                    .symbol(.circle.strokeBorder(lineWidth: 1))
                                    .symbolSize(30)
                                    .foregroundStyle(TL.Palette.ion)
                            }
                            .chartXScale(domain: 0...100)
                            .tlChartAxes(xCount: 5)
                            .frame(height: 150)
                        }
                    }
                }
            }
            .padding(TL.Space.s4)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(TL.Palette.ground)
        .navigationTitle(charge.startDate.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) {
            if let id = charge.id { samples = (try? await model.store.samples(sessionID: id)) ?? [] }
            tariff = ((try? await model.store.geofences()) ?? []).first { $0.id == charge.geofenceID }?.tariff
        }
    }

    /// The geofence's off-peak window shown behind the curve, when it overlaps the session.
    private var offPeakBand: (from: Date, to: Date, label: String)? {
        guard let w = tariff?.windows.first, let end = charge.endDate ?? samples.last?.timestamp else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: charge.startDate)
        var from = day.addingTimeInterval(Double(w.startMinute) * 60)
        var to = day.addingTimeInterval(Double(w.endMinute) * 60)
        if to <= from { to = to.addingTimeInterval(86_400) }
        if from > end { return nil }
        from = max(from, charge.startDate)
        to = min(to, end)
        return to > from ? (from, to, "Off-peak") : nil
    }

    private var rangeAdded: Double? {
        guard let a = charge.startRatedRangeKm, let b = charge.endRatedRangeKm else { return nil }
        return b - a
    }
}
