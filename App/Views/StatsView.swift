import Charts
import SwiftUI
import TeslaLinkCore

struct StatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabIsActive) private var tabIsActive
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
                ScreenHeader(title: "Insights")
                TLSegmented(options: Period.allCases, selection: $period, fill: true) { $0.rawValue }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: TL.Space.s3)], spacing: TL.Space.s3) {
                    StatTile(title: "Distance", value: f.distance(stats.distanceKm, digits: 0))
                    StatTile(title: "Drives", value: "\(stats.driveCount)")
                    StatTile(title: "Time driving", value: f.duration(minutes: stats.drivingHours * 60))
                    StatTile(title: "Efficiency", value: f.efficiency(whPerKm: stats.efficiencyWhPerKm), tone: TL.Palette.charge)
                    StatTile(title: "Energy charged", value: f.energy(stats.energyAddedKwh))
                    StatTile(title: "Charging cost", value: f.money(stats.chargeCost))
                    StatTile(title: "Cost per \(f.distanceUnit)", value: stats.costPerKm.map { f.money(model.settings.units == .metric ? $0 : $0 * Units.kmPerMile) } ?? "–")
                    StatTile(title: "Fast charging", value: stats.dcFastShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                }

                let byDay = period == .week || period == .month
                let unit: Calendar.Component = byDay ? .day : .month
                let buckets = Dictionary(grouping: inPeriod) { Calendar.current.dateInterval(of: unit, for: $0.startDate)?.start ?? $0.startDate }
                    .map { (date: $0.key, km: f.km($0.value.compactMap(\.distanceKm).reduce(0, +))) }
                    .sorted { $0.date < $1.date }
                let current = Calendar.current.dateInterval(of: unit, for: Date())?.start
                Card(title: "Distance by \(byDay ? "day" : "month")",
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
                    let xy = effPoints.map { (x: f.celsius($0.outsideTempAvgC!), y: f.whPerKm($0.efficiencyWhPerKm!)) }
                    let trend = Self.quadraticTrend(xy)
                    Card(title: "Efficiency vs temperature", lightbar: false,
                         aside: AnyView(ChartUnit(text: "\(f.efficiencyUnit) · \(f.temperatureUnit)"))) {
                        Chart {
                            ForEach(Array(effPoints.enumerated()), id: \.offset) { i, d in
                                let x = PlottableValue.value("Temperature", xy[i].x)
                                let y = PlottableValue.value(f.efficiencyUnit, xy[i].y)
                                PointMark(x: x, y: y)
                                    .symbolSize(min(220, (d.distanceKm ?? 5) * 4))
                                    .foregroundStyle(TL.Palette.ion.opacity(0.3))
                                PointMark(x: x, y: y)
                                    .symbol(.circle.strokeBorder(lineWidth: 1))
                                    .symbolSize(min(220, (d.distanceKm ?? 5) * 4))
                                    .foregroundStyle(TL.Palette.ion)
                            }
                            // Trend: dashed lightbar (Chart style board).
                            ForEach(trend, id: \.x) { p in
                                LineMark(x: .value("Temperature", p.x), y: .value(f.efficiencyUnit, p.y), series: .value("Series", "trend"))
                                    .foregroundStyle(TL.Palette.lightbar.opacity(0.8))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                                    .interpolationMethod(.monotone)
                            }
                        }
                        .tlChartAxes(xCount: 5)
                        .chartXScale(domain: .automatic(includesZero: false))
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 190)
                        ChartNote(text: "Bigger dots are longer drives. Cold weather and short trips cost the most.")
                    }
                }

                Card(title: "Battery health", lightbar: false, aside: AnyView(ChartUnit(text: "range at 100%"))) {
                    if health.count >= 2 {
                        if let pct = DegradationEstimator.healthPercent(health) {
                            HStack(alignment: .firstTextBaseline, spacing: TL.Space.s2) {
                                Text("\(pct.formatted(.number.precision(.fractionLength(1))))%")
                                    .font(TL.Typeface.readout).monospacedDigit().foregroundStyle(TL.Palette.ink)
                                Text("of first-logged range at 100%").font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                            }
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

                Card(title: "Parked drain", lightbar: false,
                     aside: AnyView(ChartLegend(items: [("Slept", TL.Palette.sleep), ("Kept awake", TL.Palette.amber)]))) {
                    if drain.isEmpty {
                        ChartNote(text: "Shows how much range you lose while parked, once a few parking periods are logged.")
                    } else {
                        let perDay = drain.map(\.rangeLostPerDayKm).reduce(0, +) / Double(drain.count)
                        HStack(alignment: .firstTextBaseline, spacing: TL.Space.s1) {
                            Text(f.km(perDay).formatted(.number.precision(.fractionLength(1))))
                                .font(TL.Typeface.readout).monospacedDigit().foregroundStyle(TL.Palette.ink)
                            Text("\(f.distanceUnit) per day").font(TL.Typeface.sans(13, .medium)).foregroundStyle(TL.Palette.inkMuted)
                        }
                        // Categorical x (one band per stay): `.ratio` widths need a band scale; on a
                        // numeric axis they resolved to zero and the chart drew nothing.
                        Chart(Array(drain.prefix(30).enumerated()), id: \.offset) { i, p in
                            BarMark(x: .value("Stay", String(i)), y: .value("per day", f.km(p.rangeLostPerDayKm)), width: .ratio(0.7))
                                .foregroundStyle((p.asleepFraction ?? 1) < 0.5 ? TL.Palette.amber : TL.Palette.sleep)
                        }
                        .tlChartAxes(xLabels: false)
                        .frame(height: 130)
                        ChartNote(text: "Amber stays kept the car awake (Sentry, climate, an app polling it).")
                    }
                }
            }
            .padding(.horizontal, TL.Space.s4)
            .padding(.bottom, TL.Space.s6)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .tlScreen()
        // Pauses while another tab is in front (PhoneRoot keeps this one alive).
        .task(id: tabIsActive ? model.dataVersion : -1) { if tabIsActive { await load() } }
    }

    /// Least-squares quadratic through the points, sampled across their x range: efficiency is
    /// worst in the cold, best around 20 °C and rises again with air conditioning.
    static func quadraticTrend(_ pts: [(x: Double, y: Double)], samples: Int = 24) -> [(x: Double, y: Double)] {
        guard pts.count >= 3, let lo = pts.map(\.x).min(), let hi = pts.map(\.x).max(), hi - lo > 1 else { return [] }
        // Normal equations for y = a + b·x + c·x², x centred for numerical stability.
        let mid = (lo + hi) / 2
        var s = [Double](repeating: 0, count: 5), t = [Double](repeating: 0, count: 3)
        for p in pts {
            let x = p.x - mid
            var xp = 1.0
            for k in 0..<5 {
                s[k] += xp
                if k < 3 { t[k] += xp * p.y }
                xp *= x
            }
        }
        let m = [[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]]
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-9 else { return [] }
        func replaced(_ col: Int) -> [[Double]] { m.enumerated().map { r, row in row.enumerated().map { c, v in c == col ? t[r] : v } } }
        let a = det(replaced(0)) / d, b = det(replaced(1)) / d, c = det(replaced(2)) / d
        return (0...samples).map { i in
            let x = lo + (hi - lo) * Double(i) / Double(samples)
            let u = x - mid
            return (x, a + b * u + c * u * u)
        }
    }

    private func load() async {
        guard let vin = model.selectedVehicle?.vin else { return }
        vehicle = try? await model.store.vehicle(vin: vin)
        drives = (try? await model.store.drives(vin: vin)) ?? []
        charges = (try? await model.store.charges(vin: vin)) ?? []
        states = (try? await model.store.states(vin: vin, from: Date().addingTimeInterval(-400 * 86_400))) ?? []
    }
}
