import Charts
import SwiftUI
import TeslaLinkCore

struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var period: Period = .month
    @State private var drives: [Drive] = []
    @State private var charges: [ChargeSession] = []
    @State private var states: [StateRecord] = []
    @State private var vehicle: Vehicle?

    enum Period: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", year = "Year", all = "All"
        var id: String { rawValue }
        var start: Date {
            switch self {
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .month: Date().addingTimeInterval(-30 * 86_400)
            case .year: Date().addingTimeInterval(-365 * 86_400)
            case .all: .distantPast
            }
        }
    }

    var body: some View {
        let f = Fmt(model.settings.units)
        let inPeriod = drives.filter { $0.startDate >= period.start && !$0.isOpen }
        let chargesInPeriod = charges.filter { $0.startDate >= period.start && !$0.isOpen }
        let stats = PeriodStats(drives: inPeriod, charges: chargesInPeriod)
        let eff = vehicle?.efficiencyKwhPerKm
        let health = DegradationEstimator.series(charges: charges, efficiencyKwhPerKm: eff)
        let drain = VampireDrainAnalyzer.periods(drives: drives, charges: charges, states: states, efficiencyKwhPerKm: eff)
            .filter { $0.start >= period.start }

        ScrollView {
            VStack(spacing: 16) {
                Picker("Period", selection: $period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: TL.Space.s3)], spacing: TL.Space.s3) {
                    StatTile(title: "Distance", value: f.distance(stats.distanceKm, digits: 0), symbol: "road.lanes")
                    StatTile(title: "Drives", value: "\(stats.driveCount)", symbol: "steeringwheel")
                    StatTile(title: "Time driving", value: f.duration(minutes: stats.drivingHours * 60), symbol: "timer")
                    StatTile(title: "Efficiency", value: f.efficiency(whPerKm: stats.efficiencyWhPerKm), symbol: "leaf", tone: TL.Palette.charge)
                    StatTile(title: "Energy charged", value: f.energy(stats.energyAddedKwh), symbol: "bolt.fill")
                    StatTile(title: "Charging cost", value: f.money(stats.chargeCost), symbol: "creditcard")
                    StatTile(title: "Cost per \(f.distanceUnit)", value: stats.costPerKm.map { f.money(model.settings.units == .metric ? $0 : $0 * Units.kmPerMile) } ?? "–", symbol: "gauge.with.dots.needle.33percent")
                    StatTile(title: "Fast charging", value: stats.dcFastShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", symbol: "bolt.circle")
                }

                let byDay = period == .week || period == .month
                let unit: Calendar.Component = byDay ? .day : .month
                let buckets = Dictionary(grouping: inPeriod) { Calendar.current.dateInterval(of: unit, for: $0.startDate)?.start ?? $0.startDate }
                    .map { (date: $0.key, km: f.km($0.value.compactMap(\.distanceKm).reduce(0, +))) }
                    .sorted { $0.date < $1.date }
                let current = Calendar.current.dateInterval(of: unit, for: Date())?.start
                Card(title: "Distance by \(byDay ? "day" : "month")", symbol: "chart.bar",
                     aside: AnyView(ChartUnit(text: buckets.isEmpty ? f.distanceUnit : "avg \(Int((buckets.map(\.km).reduce(0, +) / Double(buckets.count)).rounded())) \(f.distanceUnit)"))) {
                    Chart {
                        ForEach(buckets, id: \.date) { b in
                            BarMark(x: .value("Date", b.date, unit: unit), y: .value(f.distanceUnit, b.km), width: .ratio(0.7))
                                .foregroundStyle(TLBars.totalColor(highlighted: b.date == current))
                        }
                        if !buckets.isEmpty {
                            RuleMark(y: .value("Average", buckets.map(\.km).reduce(0, +) / Double(buckets.count)))
                                .foregroundStyle(TL.Palette.lightbar.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        }
                    }
                    .tlChartAxes()
                    .frame(height: 160)
                }

                let effPoints = inPeriod.filter { $0.efficiencyWhPerKm != nil && $0.outsideTempAvgC != nil && ($0.distanceKm ?? 0) > 3 }
                if effPoints.count >= 3 {
                    Card(title: "Efficiency vs temperature", symbol: "thermometer.snowflake", lightbar: false, aside: AnyView(ChartUnit(text: f.efficiencyUnit))) {
                        Chart(effPoints) { d in
                            let x = PlottableValue.value("Temperature", model.settings.units == .metric ? d.outsideTempAvgC! : d.outsideTempAvgC! * 9 / 5 + 32)
                            let y = PlottableValue.value(f.efficiencyUnit, model.settings.units == .metric ? d.efficiencyWhPerKm! : d.efficiencyWhPerKm! * Units.kmPerMile)
                            PointMark(x: x, y: y)
                                .symbolSize(min(220, (d.distanceKm ?? 5) * 4))
                                .foregroundStyle(TL.Palette.ion.opacity(0.3))
                            PointMark(x: x, y: y)
                                .symbol(.circle.strokeBorder(lineWidth: 1))
                                .symbolSize(min(220, (d.distanceKm ?? 5) * 4))
                                .foregroundStyle(TL.Palette.ion)
                        }
                        .tlChartAxes(xCount: 5)
                        .frame(height: 190)
                        ChartNote(text: "Bigger dots are longer drives. Cold weather and short trips cost the most.")
                    }
                }

                Card(title: "Battery health", symbol: "battery.100percent", lightbar: false, aside: AnyView(ChartUnit(text: "range at 100%"))) {
                    if health.count >= 2 {
                        if let pct = DegradationEstimator.healthPercent(health) {
                            Text("\(pct.formatted(.number.precision(.fractionLength(1))))% of first-logged range")
                                .font(TL.Typeface.title)
                        }
                        let pts = health.map { TLPoint(x: $0.date, y: f.km($0.rangeAt100Km)) }
                        let lo = pts.map(\.y).min() ?? 0, hi = pts.map(\.y).max() ?? 1
                        TLLineChart(points: pts, color: TL.Palette.ion, markMax: false, liveEnd: true,
                                    yDomain: (lo - 10)...(hi + 10), height: 140,
                                    valueFormat: { "\(Int($0.rounded())) \(f.distanceUnit)" })
                        if let cap = health.last?.capacityKwh {
                            ChartNote(text: "Estimated usable capacity: \(f.energy(cap))")
                        }
                    } else {
                        ChartNote(text: "Needs a few charges that end above 50% to project range at 100%.")
                    }
                    if let eff {
                        ChartNote(text: "Derived consumption: \(f.efficiency(whPerKm: eff * 1000)) of rated range")
                    }
                }

                Card(title: "Parked drain", symbol: "moon.zzz", lightbar: false,
                     aside: AnyView(ChartLegend(items: [("Slept", TL.Palette.sleep), ("Kept awake", TL.Palette.amber)]))) {
                    if drain.isEmpty {
                        ChartNote(text: "Shows how much range you lose while parked, once a few parking periods are logged.")
                    } else {
                        let perDay = drain.map(\.rangeLostPerDayKm).reduce(0, +) / Double(drain.count)
                        Text("≈ \(f.distance(perDay)) per day").font(TL.Typeface.title)
                        Chart(Array(drain.prefix(30).enumerated()), id: \.offset) { i, p in
                            BarMark(x: .value("Stay", i), y: .value("per day", f.km(p.rangeLostPerDayKm)), width: .ratio(0.7))
                                .foregroundStyle((p.asleepFraction ?? 1) < 0.5 ? TL.Palette.amber : TL.Palette.sleep)
                        }
                        .tlChartAxes(xLabels: false)
                        .frame(height: 130)
                        ChartNote(text: "Amber stays kept the car awake (Sentry, climate, an app polling it).")
                    }
                }
            }
            .padding(TL.Space.s4)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(TL.Palette.ground)
        .navigationTitle("Insights")
        .task(id: model.dataVersion) { await load() }
    }

    private func load() async {
        guard let vin = model.selectedVehicle?.vin else { return }
        vehicle = try? await model.store.vehicle(vin: vin)
        drives = (try? await model.store.drives(vin: vin)) ?? []
        charges = (try? await model.store.charges(vin: vin)) ?? []
        states = (try? await model.store.states(vin: vin, from: Date().addingTimeInterval(-400 * 86_400))) ?? []
    }
}
