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
        List {
            if drives.isEmpty {
                ContentUnavailableView("No drives yet", systemImage: "road.lanes",
                                       description: Text("Drives are logged automatically. Keep location set to Always for the most detail."))
            }
            ForEach(groupedByDay, id: \.0) { day, items in
                Section {
                    ForEach(items) { d in
                        NavigationLink(value: d) { DriveRow(drive: d, fences: fences, f: f) }
                    }
                    .onDelete { idx in Task { await delete(idx.map { items[$0] }) } }
                } header: {
                    HStack {
                        Text(day, format: .dateTime.weekday(.wide).day().month())
                        Spacer()
                        Text(f.distance(items.compactMap(\.distanceKm).reduce(0, +)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(place(drive.startGeofenceID, drive.startAddress)) + Text("  →  ").foregroundStyle(TL.Palette.edgeStrong) + Text(place(drive.endGeofenceID, drive.endAddress))
                Spacer()
                if drive.isOpen { Text("LIVE").tlLabel().foregroundStyle(TL.Palette.onIon).padding(.horizontal, 6).padding(.vertical, 2).background(ChamferedRectangle(cut: 4).fill(TL.Palette.ion)) }
                if drive.isInferred { Image(systemName: "questionmark.circle").foregroundStyle(TL.Palette.inkMuted).help("Reconstructed: the app wasn't running during this drive") }
            }
            .font(TL.Typeface.bodyStrong)
            .lineLimit(1)
            HStack(spacing: 14) {
                Label(drive.startDate.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                Label(f.distance(drive.distanceKm), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                Label(f.duration(minutes: drive.durationMin), systemImage: "timer")
                if let e = drive.efficiencyWhPerKm { Label(f.efficiency(whPerKm: e), systemImage: "leaf") }
            }
            .font(TL.Typeface.caption)
            .foregroundStyle(TL.Palette.inkMuted)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
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
                Map {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg.coords).stroke(seg.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                    if let a = positions.first { Marker("Start", systemImage: "flag", coordinate: a.coordinate).tint(.green) }
                    if let b = positions.last { Marker("End", systemImage: "flag.checkered", coordinate: b.coordinate).tint(.red) }
                }
                .frame(height: 320)
                .clipShape(ChamferedRectangle(cut: TL.Chamfer.lg))

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
        .navigationTitle(drive.startDate.formatted(date: .abbreviated, time: .shortened))
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
            out.append(([pts[i - 1].coordinate, pts[i].coordinate], Color(hue: 0.66 - 0.66 * t, saturation: 0.85, brightness: 0.9)))
        }
        return out
    }
}

extension Position {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}
