import Charts
import SwiftUI
import TeslaLinkCore

struct ChargesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabIsActive) private var tabIsActive
    /// Set on the open Duo: the live card and rows select into the right pane instead of pushing.
    @Environment(\.paneSelection) private var pane
    @State private var charges: [ChargeSession] = []
    @State private var fences: [RecordID: String] = [:]

    var body: some View {
        let f = Fmt(model.settings.units)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Charging")
                if let live = charges.first(where: \.isOpen), let vin = model.selectedVehicle?.vin {
                    Group {
                        if let pane {
                            Button { pane.liveCharge = true } label: { liveCard(live, vin: vin, f: f, selected: pane.liveCharge) }
                                .accessibilityAddTraits(pane.liveCharge ? .isSelected : [])
                        } else {
                            NavigationLink { LiveChargeView(vin: vin, backTitle: "Charging") } label: { liveCard(live, vin: vin, f: f, selected: false) }
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
                            let selected = pane.map { !$0.liveCharge && $0.charge?.id == c.id } ?? false
                            let row = ChargeRow(charge: c, place: c.geofenceID.flatMap { fences[$0] }, f: f).tlRow(selected: selected)
                            Group {
                                if let pane {
                                    Button {
                                        pane.charge = c
                                        pane.liveCharge = false
                                    } label: { row }
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                } else {
                                    NavigationLink(value: c) { row }
                                }
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
        .onChange(of: pane != nil, initial: true) { _, _ in syncSelection() }
    }

    /// The running session: energy so far and charger power, as a hero card.
    private func liveCard(_ live: ChargeSession, vin: String, f: Fmt, selected: Bool) -> some View {
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
                if pane == nil {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(TL.Palette.inkMuted)
                }
            }
        }
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(TL.Palette.ion).frame(width: 2).padding(.vertical, 18).tlGlow(radius: 6)
            }
        }
    }

    /// Open Duo: what the right pane shows. Defaults to the running session, else the newest
    /// finished one; when the running session ends, it moves to that finished session.
    private func syncSelection() {
        guard let pane, !charges.isEmpty else { return }   // nothing loaded yet: keep the selection
        let live = charges.first(where: \.isOpen)
        let finished = charges.filter { !$0.isOpen }
        if pane.liveCharge {
            if live != nil { return }
            pane.liveCharge = false
            pane.charge = finished.first
            return
        }
        if let current = pane.charge, let fresh = finished.first(where: { $0.id == current.id }) {
            pane.charge = fresh
        } else if live != nil {
            pane.liveCharge = true
            pane.charge = nil
        } else {
            pane.charge = finished.first
        }
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
        syncSelection()
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
    /// The back link's title; nil in the open Duo's right pane, where there's nothing to go back to.
    var backTitle: String? = "Charging"
    @Environment(\.paneSelection) private var pane
    @Environment(\.dismiss) private var dismiss
    @State private var samples: [ChargeSample] = []
    @State private var tariff: Tariff?
    @State private var placeName: String?

    var body: some View {
        let f = Fmt(model.settings.units)
        ScrollView {
            VStack(spacing: TL.Space.s4) {
                ScreenHeader(back: backTitle,
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
        .onChange(of: pane != nil, initial: true) { _, inPanes in
            // Unfolded while this session was pushed on the outer screen: hand it to the right pane.
            if inPanes, backTitle != nil, let pane {
                pane.charge = charge
                pane.liveCharge = false
                dismiss()
            }
        }
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
