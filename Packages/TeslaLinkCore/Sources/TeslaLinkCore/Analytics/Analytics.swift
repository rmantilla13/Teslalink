import Foundation

/// Derives the car's consumption per rated km from logged charges.
///
/// Idea (same as TeslaMate's): the car's "rated range" is just battery energy divided by a
/// fixed factor. For every clean AC charge, energy_added / rated_range_added gives that factor.
/// Round it and take the most common value; require more agreement at finer precision.
public enum EfficiencyEstimator {
    public static let passes: [(decimals: Int, minCount: Int)] = [(5, 8), (4, 5), (3, 3), (2, 2)]

    public static func estimate(from charges: [ChargeSession]) -> (kwhPerKm: Double, confirmations: Int)? {
        let ratios = charges.compactMap { c -> Double? in
            guard let m = c.durationMin, m > 10,
                  let end = c.endBatteryLevel, end <= 95,
                  let e = c.energyAddedKwh, e > 0,
                  let a = c.startRatedRangeKm, let b = c.endRatedRangeKm, b - a > 0 else { return nil }
            return e / (b - a)
        }
        for pass in passes {
            let scale = pow(10, Double(pass.decimals))
            var counts: [Double: Int] = [:]
            for r in ratios { counts[(r * scale).rounded() / scale, default: 0] += 1 }
            if let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
               best.value >= pass.minCount, best.key > 0 {
                return (best.key, best.value)
            }
        }
        return nil
    }
}

/// Battery health: projects the rated range at 100% and the usable capacity.
public enum DegradationEstimator {
    public struct Point: Sendable, Equatable {
        public var date: Date
        public var rangeAt100Km: Double
        public var capacityKwh: Double?
    }

    /// Uses the end of each charge (most stable reading). Charges ending below 50% are noisy.
    public static func series(charges: [ChargeSession], efficiencyKwhPerKm: Double?) -> [Point] {
        charges.compactMap { c in
            guard let end = c.endDate, let soc = c.endBatteryLevel, soc >= 50, let r = c.endRatedRangeKm, r > 0 else { return nil }
            let full = r / (Double(soc) / 100)
            return Point(date: end, rangeAt100Km: full, capacityKwh: efficiencyKwhPerKm.map { full * $0 })
        }
        .sorted { $0.date < $1.date }
    }

    /// Percent of original range remaining, comparing the median of the first and last few points.
    public static func healthPercent(_ series: [Point], window: Int = 5) -> Double? {
        guard series.count >= 2 else { return nil }
        let first = median(series.prefix(window).map(\.rangeAt100Km))
        let last = median(series.suffix(window).map(\.rangeAt100Km))
        guard let first, let last, first > 0 else { return nil }
        return min(100, last / first * 100)
    }
}

/// Energy lost while parked (sentry, cabin overheat protection, idle drain).
public struct ParkingPeriod: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var rangeLostKm: Double
    public var socLost: Int
    public var energyLostKwh: Double?
    /// Fraction of the period the car was asleep (0...1), if known.
    public var asleepFraction: Double?

    public var hours: Double { end.timeIntervalSince(start) / 3600 }
    public var rangeLostPerDayKm: Double { hours > 0 ? rangeLostKm / hours * 24 : 0 }
    public var wattsAverage: Double? { energyLostKwh.map { hours > 0 ? $0 * 1000 / hours : 0 } }
}

public enum VampireDrainAnalyzer {
    /// Builds parking periods from the gaps between activities (drive or charge).
    public static func periods(drives: [Drive], charges: [ChargeSession], states: [StateRecord] = [],
                               efficiencyKwhPerKm: Double?, minHours: Double = 1) -> [ParkingPeriod] {
        struct Edge { var start: Date; var end: Date; var startRange: Double?; var endRange: Double?; var startSoc: Int?; var endSoc: Int? }
        let edges: [Edge] =
            drives.compactMap { d in d.endDate.map { Edge(start: d.startDate, end: $0, startRange: d.startRatedRangeKm, endRange: d.endRatedRangeKm, startSoc: d.startBatteryLevel, endSoc: d.endBatteryLevel) } } +
            charges.compactMap { c in c.endDate.map { Edge(start: c.startDate, end: $0, startRange: c.startRatedRangeKm, endRange: c.endRatedRangeKm, startSoc: c.startBatteryLevel, endSoc: c.endBatteryLevel) } }
        let sorted = edges.sorted { $0.start < $1.start }
        guard sorted.count > 1 else { return [] }

        var out: [ParkingPeriod] = []
        for i in 1..<sorted.count {
            let a = sorted[i - 1], b = sorted[i]
            let hours = b.start.timeIntervalSince(a.end) / 3600
            guard hours >= minHours, let r0 = a.endRange, let r1 = b.startRange, let s0 = a.endSoc, let s1 = b.startSoc else { continue }
            let lost = max(0, r0 - r1)
            let asleep = asleepSeconds(states, from: a.end, to: b.start) / (hours * 3600)
            out.append(ParkingPeriod(start: a.end, end: b.start, rangeLostKm: lost, socLost: max(0, s0 - s1),
                                     energyLostKwh: efficiencyKwhPerKm.map { lost * $0 },
                                     asleepFraction: states.isEmpty ? nil : asleep))
        }
        return out
    }

    static func asleepSeconds(_ states: [StateRecord], from: Date, to: Date) -> Double {
        states.filter { $0.kind == .asleep || $0.kind == .offline }.reduce(0) { sum, s in
            let start = max(s.startDate, from), end = min(s.endDate ?? to, to)
            return sum + max(0, end.timeIntervalSince(start))
        }
    }
}

/// When the app wasn't running (iOS suspended it), two snapshots can straddle activity we
/// never saw. This infers what happened between them.
public enum GapReconciler {
    public enum Finding: Sendable, Equatable {
        case missedDrive(Drive)
        case missedCharge(ChargeSession)
    }

    public static func reconcile(from a: VehicleSnapshot, to b: VehicleSnapshot, minDistanceKm: Double = 0.2) -> [Finding] {
        var out: [Finding] = []
        if let o0 = a.odometerKm, let o1 = b.odometerKm, o1 - o0 >= minDistanceKm {
            var d = Drive(vin: a.vin, startDate: a.timestamp, isInferred: true)
            d.endDate = b.timestamp
            d.startOdometerKm = o0
            d.endOdometerKm = o1
            d.distanceKm = o1 - o0
            d.startLatitude = a.latitude; d.startLongitude = a.longitude
            d.endLatitude = b.latitude; d.endLongitude = b.longitude
            d.startBatteryLevel = a.batteryLevel; d.endBatteryLevel = b.batteryLevel
            d.startRatedRangeKm = a.ratedRangeKm; d.endRatedRangeKm = b.ratedRangeKm
            // The true duration is unknown; the span between snapshots is an upper bound.
            d.durationMin = b.timestamp.timeIntervalSince(a.timestamp) / 60
            out.append(.missedDrive(d))
        }
        if let s0 = a.batteryLevel, let s1 = b.batteryLevel, s1 - s0 >= 2, b.chargingState?.isActive != true {
            var c = ChargeSession(vin: a.vin, startDate: a.timestamp)
            c.endDate = b.timestamp
            c.startBatteryLevel = s0; c.endBatteryLevel = s1
            c.startRatedRangeKm = a.ratedRangeKm; c.endRatedRangeKm = b.ratedRangeKm
            c.latitude = b.latitude; c.longitude = b.longitude
            // A finished charge keeps charge_energy_added until the next one starts.
            if b.chargingState == .complete || b.chargingState == .stopped { c.energyAddedKwh = b.chargeEnergyAddedKwh }
            c.durationMin = nil
            out.append(.missedCharge(c))
        }
        return out
    }
}

public struct PeriodStats: Sendable, Equatable {
    public var driveCount = 0
    public var distanceKm = 0.0
    public var drivingHours = 0.0
    public var energyUsedKwh = 0.0
    public var chargeCount = 0
    public var energyAddedKwh = 0.0
    public var chargeCost = 0.0
    public var dcFastShare: Double?

    public var efficiencyWhPerKm: Double? { distanceKm > 1 ? energyUsedKwh * 1000 / distanceKm : nil }
    public var costPerKm: Double? { distanceKm > 1 && chargeCost > 0 ? chargeCost / distanceKm : nil }

    public init() {}

    public init(drives: [Drive], charges: [ChargeSession]) {
        for d in drives {
            driveCount += 1
            distanceKm += d.distanceKm ?? 0
            drivingHours += (d.durationMin ?? 0) / 60
            energyUsedKwh += d.energyUsedKwh ?? 0
        }
        var dc = 0.0
        for c in charges {
            chargeCount += 1
            energyAddedKwh += c.energyAddedKwh ?? 0
            chargeCost += c.cost ?? 0
            if c.isDCFast { dc += c.energyAddedKwh ?? 0 }
        }
        dcFastShare = energyAddedKwh > 0 ? dc / energyAddedKwh : nil
    }
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
