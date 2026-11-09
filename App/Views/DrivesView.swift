import Charts
import MapKit
import SwiftUI
import TeslaLinkCore

struct DrivesView: View {
    @Environment(AppModel.self) private var model
    @State private var drives: [Drive] = []
    @State private var fences: [RecordID: String] = [:]

    var body: some View {
        let f = Fmt(model.settings.units)
        let week = drives.filter { !$0.isOpen && $0.startDate >= Calendar.current.date(byAdding: .day, value: -7, to: Date())! }
        let weekStats = PeriodStats(drives: week, charges: [])
        let typical = weekStats.efficiencyWhPerKm ?? PeriodStats(drives: drives.filter { !$0.isOpen }, charges: []).efficiencyWhPerKm

        List {
            if drives.isEmpty {
                ContentUnavailableView("No drives yet", systemImage: "road.lanes",
                                       description: Text("Drives are logged automatically. Keep location set to Always for the most detail."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    Card(title: "This week", symbol: "calendar") {
                        HStack(alignment: .top, spacing: TL.Space.s6) {
                            Metric(label: "Distance", value: f.distance(weekStats.distanceKm, digits: 0))
                            Metric(label: "Energy", value: f.energy(weekStats.energyUsedKwh))
                            Metric(label: "Average", value: f.efficiency(whPerKm: weekStats.efficiencyWhPerKm), tone: TL.Palette.charge)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(groupedByDay, id: \.0) { day, items in
                Section {
                    ForEach(items) { d in
                        NavigationLink(value: d) { DriveRow(drive: d, fences: fences, f: f, typicalWhPerKm: typical) }
                            .listRowBackground(d.isOpen ? TL.Palette.ion.opacity(0.07) : TL.Palette.surface1)
                    }
                    .onDelete { idx in Task { await delete(idx.map { items[$0] }) } }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(dayTitle(day)).tlLabel().foregroundStyle(TL.Palette.ink)
                        Spacer()
                        Text(f.distance(items.compactMap(\.distanceKm).reduce(0, +))).font(TL.Typeface.mono(12)).foregroundStyle(TL.Palette.inkMuted)
                    }
                }
            }
        }
        .tlListStyle()
        .navigationTitle("Drives")
        .navigationDestination(for: Drive.self) { DriveDetailView(drive: $0) }
        .task(id: model.dataVersion) { await load() }
        .refreshable { await load() }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }

    private var groupedByDay: [(Date, [Drive])] {
        let cal = Calendar.current
        return Dictionary(grouping: drives) { cal.startOfDay(for: $0.startDate) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.startDate > $1.startDate }) }
    }

    private func load() async {
        guard let vin = model.selectedVehicle?.vin else { return }
        drives = (try? await model.store.drives(vin: vin, limit: 500)) ?? []
        fences = Dictionary(uniqueKeysWithValues: ((try? await model.store.geofences()) ?? []).compactMap { g in g.id.map { ($0, g.name) } })
    }

    private func delete(_ items: [Drive]) async {
        for d in items { if let id = d.id { try? await model.store.deleteDrive(id: id) } }
        model.markDataChanged()
    }
}

struct DriveRow: View {
    let drive: Drive
    let fences: [RecordID: String]
    let f: Fmt
    var typicalWhPerKm: Double?

    var body: some View {
        HStack(spacing: TL.Space.s3) {
            RouteThumbnail(drive: drive)
            VStack(alignment: .leading, spacing: 2) {
                title.font(TL.Typeface.bodyStrong).foregroundStyle(TL.Palette.ink).lineLimit(1)
                meta.font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted).lineLimit(1)
            }
            Spacer(minLength: TL.Space.s2)
            if drive.isOpen {
                Text("LIVE").tlLabel().foregroundStyle(TL.Palette.onIon)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ChamferedRectangle(cut: 4).fill(TL.Palette.ion))
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(f.distance(drive.distanceKm)).font(TL.Typeface.display(17, .medium)).monospacedDigit().foregroundStyle(TL.Palette.ink)
                    Text(efficiencyText).font(TL.Typeface.mono(12)).foregroundStyle(efficiencyColor)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: Text {
        if drive.isOpen {
            return Text(place(drive.startGeofenceID, drive.startAddress)) + Text(" → ").foregroundColor(TL.Palette.edgeStrong)
                + Text("driving").foregroundColor(TL.Palette.inkMuted)
        }
        return Text(place(drive.startGeofenceID, drive.startAddress)) + Text(" → ").foregroundColor(TL.Palette.edgeStrong)
            + Text(place(drive.endGeofenceID, drive.endAddress))
    }

    private var meta: Text {
        let time = drive.startDate.formatted(date: .omitted, time: .shortened)
        if drive.isOpen { return Text("\(time) · \(f.distance(drive.distanceKm)) so far") }
        if drive.isInferred { return Text(Image(systemName: "questionmark.circle")) + Text(" Reconstructed · app was closed") }
        var parts = [time, f.duration(minutes: drive.durationMin)]
        if let up = drive.ascentM, up >= 100 { parts.append("↑ \(f.elevation(up))") }
        return Text(parts.joined(separator: " · "))
    }

    private var efficiencyText: String {
        guard let e = drive.efficiencyWhPerKm else { return "–" }
        return (drive.isInferred ? "≈" : "") + f.efficiency(whPerKm: e)
    }

    /// Green when better than your typical consumption, amber when clearly worse.
    private var efficiencyColor: Color {
        guard let e = drive.efficiencyWhPerKm, !drive.isInferred, let typical = typicalWhPerKm else { return TL.Palette.inkMuted }
        if e <= typical { return TL.Palette.charge }
        if e > typical * 1.08 { return TL.Palette.amber }
        return TL.Palette.ink
    }

    private func place(_ fence: RecordID?, _ address: String?) -> String {
        fence.flatMap { fences[$0] } ?? address ?? "Unknown"
    }
}

struct DriveDetailView: View {
    @Environment(AppModel.self) private var model
    let drive: Drive
    @State private var positions: [Position] = []
    @State private var colorBy: ColorBy = .speed

    enum ColorBy: String, CaseIterable { case speed = "Speed", power = "Power", elevation = "Elevation" }

    var body: some View {
        let f = Fmt(model.settings.units)
        ScrollView {
            VStack(spacing: TL.Space.s6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.startDate.formatted(.dateTime.weekday(.abbreviated).day().month()) + " · "
                         + drive.startDate.formatted(date: .omitted, time: .shortened)
                         + (drive.endDate.map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                        .tlLabel()
                    (Text(drive.startAddress ?? "Start") + Text(" → ").foregroundColor(TL.Palette.edgeStrong) + Text(drive.endAddress ?? (drive.isOpen ? "driving" : "End")))
                        .font(TL.Typeface.display(28))
                        .foregroundStyle(TL.Palette.ink)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Map {
                    // Glow under the route, then the route coloured by the chosen metric.
                    MapPolyline(coordinates: positions.map(\.coordinate))
                        .stroke(TL.Palette.ion.opacity(0.25), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg.coords).stroke(seg.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                    if let a = positions.first {
                        Annotation("Start", coordinate: a.coordinate) { MapPin(color: TL.Palette.charge) }
                    }
                    if let b = positions.last, !drive.isOpen {
                        Annotation("End", coordinate: b.coordinate) { MapPin(color: TL.Palette.ink) }
                    }
                    if colorBy == .speed, let top = positions.filter({ $0.speedKmh != nil }).max(by: { $0.speedKmh! < $1.speedKmh! }) {
                        Annotation("Top speed", coordinate: top.coordinate, anchor: .bottom) {
                            ValueTag(text: f.speed(top.speedKmh), color: TL.Palette.lightbar)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .environment(\.colorScheme, .dark)
                .frame(height: 300)
                .clipShape(ChamferedRectangle(cut: TL.Chamfer.lg))
                .overlay(alignment: .bottom) {
                    if colorBy == .speed { HeatLegend(low: "0", high: f.speed(positions.compactMap(\.speedKmh).max())).padding(12) }
                }

                TLSegmented(options: ColorBy.allCases, selection: $colorBy) { $0.rawValue }

                Card(title: "Summary", symbol: "list.bullet.rectangle") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow { Metric(label: "Distance", value: f.distance(drive.distanceKm)); Metric(label: "Duration", value: f.duration(minutes: drive.durationMin)) }
                        GridRow { Metric(label: "Avg speed", value: f.speed(drive.averageSpeedKmh)); Metric(label: "Top speed", value: f.speed(drive.speedMaxKmh)) }
                        GridRow { Metric(label: "Energy", value: f.energy(drive.energyUsedKwh)); Metric(label: "Efficiency", value: f.efficiency(whPerKm: drive.efficiencyWhPerKm)) }
                        GridRow { Metric(label: "Battery", value: "\(drive.startBatteryLevel.map(String.init) ?? "–")% → \(drive.endBatteryLevel.map(String.init) ?? "–")%")
                                  Metric(label: "Range used", value: f.distance(rangeUsed, digits: 0)) }
                        GridRow { Metric(label: "Ascent", value: f.elevation(drive.ascentM)); Metric(label: "Descent", value: f.elevation(drive.descentM)) }
                        GridRow { Metric(label: "Max power", value: f.power(drive.powerMaxKw)); Metric(label: "Max regen", value: f.power(drive.powerMinKw.map { -$0 })) }
                        GridRow { Metric(label: "Outside", value: f.temperature(drive.outsideTempAvgC)); Metric(label: "Inside", value: f.temperature(drive.insideTempAvgC)) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if drive.isInferred {
                        Label("Reconstructed from before/after readings; the route and timing are approximate.", systemImage: "info.circle")
                            .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                    }
                }

                let speed = positions.compactMap { p in p.speedKmh.map { TLPoint(x: p.timestamp, y: f.km($0)) } }
                if speed.count > 2 {
                    Card(title: "Speed", symbol: "speedometer", lightbar: false, aside: AnyView(ChartUnit(text: f.speedUnit))) {
                        TLLineChart(points: speed, color: TL.Palette.ion, height: 150)
                    }
                }
                let power = positions.filter { $0.powerKw != nil && $0.source != .phone }
                if power.count > 2 {
                    Card(title: "Power", symbol: "bolt", lightbar: false,
                         aside: AnyView(ChartLegend(items: [("Drive", TL.Palette.ion), ("Regen", TL.Palette.charge)]))) {
                        Chart(power, id: \.timestamp) { p in
                            BarMark(x: .value("Time", p.timestamp), y: .value("kW", p.powerKw!))
                                .foregroundStyle(TLBars.signedColor(p.powerKw!))
                            RuleMark(y: .value("Zero", 0)).foregroundStyle(TL.Palette.edgeStrong).lineStyle(StrokeStyle(lineWidth: 1))
                        }
                        .tlChartAxes()
                        .frame(height: 130)
                    }
                }
                let elevation = positions.compactMap { p in p.elevationM.map { TLPoint(x: p.timestamp, y: $0) } }
                if elevation.count > 5, let lo = elevation.map(\.y).min(), let hi = elevation.map(\.y).max() {
                    Card(title: "Elevation", symbol: "mountain.2", lightbar: false,
                         aside: AnyView(ChartUnit(text: "\(f.elevation(lo)) – \(f.elevation(hi))"))) {
                        TLLineChart(points: elevation, color: TL.Palette.steel, markMax: false,
                                    yDomain: (lo - 10)...(hi + 10), height: 90)
                    }
                }
            }
            .padding(TL.Space.s4)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(TL.Palette.ground)
        .navigationTitle("Drive")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) {
            if let id = drive.id { positions = (try? await model.store.positions(driveID: id)) ?? [] }
        }
    }

    private var rangeUsed: Double? {
        guard let a = drive.startRatedRangeKm, let b = drive.endRatedRangeKm else { return nil }
        return a - b
    }

    /// Splits the track into short runs coloured by the chosen metric.
    /// Route heat scale: edge-strong → ion → lightbar.
    static func heat(_ t: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [(0, (0.40, 0.44, 0.48)), (0.5, (0.30, 0.79, 1.0)), (1, (0.91, 0.97, 1.0))]
        let x = max(0, min(1, t))
        let (a, b) = x < 0.5 ? (stops[0], stops[1]) : (stops[1], stops[2])
        let u = (x - a.0) / (b.0 - a.0)
        return Color(red: a.1.0 + (b.1.0 - a.1.0) * u, green: a.1.1 + (b.1.1 - a.1.1) * u, blue: a.1.2 + (b.1.2 - a.1.2) * u)
    }

    private var segments: [(coords: [CLLocationCoordinate2D], color: Color)] {
        let pts = positions
        guard pts.count > 1 else { return [] }
        let values: [Double?] = pts.map {
            switch colorBy {
            case .speed: $0.speedKmh
            case .power: $0.powerKw
            case .elevation: $0.elevationM
            }
        }
        let known = values.compactMap { $0 }
        let lo = known.min() ?? 0, hi = max(known.max() ?? 1, lo + 1)
        var out: [(coords: [CLLocationCoordinate2D], color: Color)] = []
        for i in 1..<pts.count {
            let v = values[i] ?? values[i - 1]
            let t = v.map { ($0 - lo) / (hi - lo) } ?? 0.5
            out.append(([pts[i - 1].coordinate, pts[i].coordinate], Self.heat(t)))
        }
        return out
    }
}

extension Position {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Chamfered square marker for route start and end.
struct MapPin: View {
    let color: Color
    var body: some View {
        ChamferedRectangle(cut: 3)
            .fill(color)
            .frame(width: 12, height: 12)
            .shadow(color: color.opacity(0.6), radius: 6)
    }
}

/// The route heat scale shown under the map.
struct HeatLegend: View {
    let low: String
    let high: String
    var body: some View {
        HStack(spacing: TL.Space.s2) {
            Text(low)
            LinearGradient(colors: [DriveDetailView.heat(0), DriveDetailView.heat(0.5), DriveDetailView.heat(1)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 3)
            Text(high)
        }
        .font(TL.Typeface.mono(10))
        .foregroundStyle(TL.Palette.inkMuted)
    }
}
