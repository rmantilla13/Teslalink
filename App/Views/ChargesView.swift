import Charts
import SwiftUI
import TeslaLinkCore

struct ChargesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabIsActive) private var tabIsActive
    @State private var charges: [ChargeSession] = []
    @State private var fences: [RecordID: String] = [:]

    var body: some View {
        let f = Fmt(model.settings.units)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Charging")
                if let live = charges.first(where: \.isOpen), let vin = model.selectedVehicle?.vin {
                    NavigationLink { LiveChargeView(vin: vin, backTitle: "Charging") } label: {
                        Card(title: "Charging now", hero: true) {
                            HStack(spacing: TL.Space.s3) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("+" + f.energy(live.energyAddedKwh))
                                        .font(TL.Typeface.display(28))
                                        .monospacedDigit()
                                        .foregroundStyle(TL.Palette.charge)
                                    Text(f.power(model.status(for: vin).snapshot?.chargerPowerKw) + " · " + f.duration(minutes: live.durationMin) + " so far")
                                        .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(TL.Palette.inkMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if charges.isEmpty {
                    ContentUnavailableView("No charging sessions yet", systemImage: "bolt.car",
                                           description: Text("Plug in and TeslaLink will log the session, even from sparse background updates."))
                }
                ForEach(groupedByMonth, id: \.0) { month, items in
                    HStack(alignment: .firstTextBaseline) {
                        Text(month.formatted(.dateTime.month(.wide).year())).tlLabel().foregroundStyle(TL.Palette.ink)
                        Spacer()
                        Text(f.energy(items.compactMap(\.energyAddedKwh).reduce(0, +))).font(TL.Typeface.mono(12)).foregroundStyle(TL.Palette.inkMuted)
                    }
                    .padding(.top, 6)
                    .padding(.horizontal, 2)
                    RowGroup {
                        ForEach(items) { c in
                            NavigationLink(value: c) {
                                ChargeRow(charge: c, place: c.geofenceID.flatMap { fences[$0] }, f: f).tlRow()
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete charge", systemImage: "trash", role: .destructive) { Task { await delete([c]) } }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, TL.Space.s4)
            .padding(.bottom, TL.Space.s6)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .tlScreen()
        .navigationDestination(for: ChargeSession.self) { ChargeDetailView(charge: $0) }
        // Pauses while another tab is in front (PhoneRoot keeps this one alive).
        .task(id: tabIsActive ? model.dataVersion : -1) { if tabIsActive { await load() } }
        .refreshable { await load() }
    }

    private var groupedByMonth: [(Date, [ChargeSession])] {
        let cal = Calendar.current
        return Dictionary(grouping: charges.filter { !$0.isOpen }) { cal.dateInterval(of: .month, for: $0.startDate)?.start ?? $0.startDate }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.startDate > $1.startDate }) }
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

/// One finished session: a glyph tile, where and when, energy added, battery span and cost.
struct ChargeRow: View {
    let charge: ChargeSession
    let place: String?
    let f: Fmt

    var body: some View {
        let c = charge
        HStack(spacing: TL.Space.s3) {
            Image(systemName: c.isDCFast ? "bolt.fill" : "powerplug.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(c.isDCFast ? TL.Palette.amber : TL.Palette.charge)
                .frame(width: 52, height: 40)
                .background(ChamferedRectangle(cut: TL.Chamfer.sm).fill(TL.Palette.ground.opacity(0.6)))
                .accessibilityLabel(c.isDCFast ? "Fast charger" : "AC charging")
            VStack(alignment: .leading, spacing: 2) {
                Text(place ?? c.address ?? (c.isDCFast ? "Fast charger" : "Charging"))
                    .font(TL.Typeface.bodyStrong).foregroundStyle(TL.Palette.ink).lineLimit(1)
                // Month is in the group header; start time is on the detail screen.
                Text("\(c.startDate.formatted(.dateTime.weekday(.abbreviated).day())) · \(f.duration(minutes: c.durationMin))")
                    .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted).lineLimit(1)
            }
            Spacer(minLength: TL.Space.s2)
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(f.energy(c.energyAddedKwh))").font(TL.Typeface.display(17, .medium)).monospacedDigit().foregroundStyle(TL.Palette.charge)
                Text("\(c.startBatteryLevel.map(String.init) ?? "–") → \(c.endBatteryLevel.map(String.init) ?? "–")%"
                     + (c.cost.map { " · " + f.money($0) } ?? ""))
                    .font(TL.Typeface.mono(12)).foregroundStyle(TL.Palette.inkMuted).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ChargeDetailView: View {
    @Environment(AppModel.self) private var model
    let charge: ChargeSession
    @State private var samples: [ChargeSample] = []
    @State private var tariff: Tariff?
    @State private var placeName: String?

    var body: some View {
        let f = Fmt(model.settings.units)
        ScrollView {
            VStack(spacing: TL.Space.s4) {
                ScreenHeader(back: "Charging",
                             label: charge.startDate.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()),
                             title: placeName ?? charge.address ?? (charge.isDCFast ? "Fast charger" : "Charging"),
                             titleSize: 30)
                Card(title: "Session") {
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
                    Card(title: "Charge curve", hero: true, aside: AnyView(ChartUnit(text: "kW"))) {
                        TLLineChart(points: curve, color: TL.Palette.charge, liveEnd: charge.isOpen,
                                    band: offPeakBand, height: 170, valueFormat: { "\(Int($0.rounded())) kW" })
                        if let peak = charge.powerMaxKw {
                            ChartNote(text: "Peak \(Int(peak.rounded())) kW\(charge.isDCFast ? ". Power tapers as the battery fills." : ".")")
                        }
                    }
                    let bySoc = samples.filter { $0.chargerPowerKw != nil && $0.batteryLevel != nil }
                    if bySoc.count > 2 {
                        Card(title: "Power vs battery level", lightbar: false, aside: AnyView(ChartUnit(text: "kW · %"))) {
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
            .padding(.horizontal, TL.Space.s4)
            .padding(.bottom, TL.Space.s6)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .tlScreen()
        .task(id: model.dataVersion) {
            if let id = charge.id { samples = (try? await model.store.samples(sessionID: id)) ?? [] }
            let fence = ((try? await model.store.geofences()) ?? []).first { $0.id == charge.geofenceID }
            tariff = fence?.tariff
            placeName = fence?.name
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
