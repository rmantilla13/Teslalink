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

                Card(title: "Distance by \(period == .week || period == .month ? "day" : "month")", symbol: "chart.bar") {
                    Chart(inPeriod) { d in
                        BarMark(x: .value("Date", d.startDate, unit: period == .week || period == .month ? .day : .month),
                                y: .value(f.distanceUnit, f.km(d.distanceKm ?? 0)))
                        .foregroundStyle(TL.Palette.steel)
                    }
                    .frame(height: 180)
                }

                let effPoints = inPeriod.filter { $0.efficiencyWhPerKm != nil && $0.outsideTempAvgC != nil && ($0.distanceKm ?? 0) > 3 }
                if effPoints.count >= 3 {
                    Card(title: "Efficiency vs temperature", symbol: "thermometer.snowflake") {
                        Chart(effPoints) { d in
                            PointMark(x: .value("°", model.settings.units == .metric ? d.outsideTempAvgC! : d.outsideTempAvgC! * 9 / 5 + 32),
                                      y: .value(f.efficiencyUnit, model.settings.units == .metric ? d.efficiencyWhPerKm! : d.efficiencyWhPerKm! * Units.kmPerMile))
                                .symbolSize(min(200, (d.distanceKm ?? 5) * 4))
                                .opacity(0.7)
                        }
                        .frame(height: 200)
                        Text("Bigger dots are longer drives. Cold weather and short trips cost the most.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card(title: "Battery health", symbol: "battery.100percent") {
                    if health.count >= 2 {
                        if let pct = DegradationEstimator.healthPercent(health) {
                            Text("\(pct.formatted(.number.precision(.fractionLength(1))))% of first-logged range")
                                .font(TL.Typeface.title)
                        }
                        Chart(health, id: \.date) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Range at 100%", f.km(p.rangeAt100Km)))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(TL.Palette.ion)
                            PointMark(x: .value("Date", p.date), y: .value("Range at 100%", f.km(p.rangeAt100Km))).symbolSize(12)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 180)
                        if let cap = health.last?.capacityKwh {
                            Text("Estimated usable capacity: \(f.energy(cap))").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Needs a few charges that end above 50% to project range at 100%.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let eff {
                        Text("Derived consumption: \(f.efficiency(whPerKm: eff * 1000)) of rated range")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card(title: "Parked drain", symbol: "moon.zzz") {
                    if drain.isEmpty {
                        Text("Shows how much range you lose while parked, once a few parking periods are logged.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        let perDay = drain.map(\.rangeLostPerDayKm).reduce(0, +) / Double(drain.count)
                        Text("≈ \(f.distance(perDay)) per day").font(TL.Typeface.title)
                        Chart(drain.prefix(30), id: \.start) { p in
                            BarMark(x: .value("Parked", p.start), y: .value("per day", f.km(p.rangeLostPerDayKm)))
                                .foregroundStyle((p.asleepFraction ?? 1) < 0.5 ? TL.Palette.amber : TL.Palette.sleep)
                        }
                        .frame(height: 150)
                        Text("Amber: the car was awake for most of the stay (Sentry, climate, an app keeping it up).")
                            .font(.caption).foregroundStyle(.secondary)
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
