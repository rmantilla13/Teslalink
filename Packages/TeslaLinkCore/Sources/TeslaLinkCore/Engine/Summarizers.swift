import Foundation

/// Turns a drive's positions into its summary row.
public enum DriveSummarizer {
    /// - Parameter efficiencyKwhPerKm: the car's derived consumption per rated km. When present,
    ///   energy used is computed from rated range lost, like TeslaMate does.
    /// - Parameter closing: false for a drive still in progress: running totals are filled in
    ///   but `endDate` stays nil so the drive remains open.
    public static func summarize(_ drive: Drive, positions: [Position], efficiencyKwhPerKm: Double?, closing: Bool = true) -> Drive {
        var d = drive
        let sorted = positions.sorted { $0.timestamp < $1.timestamp }
        guard let first = sorted.first, let last = sorted.last else { return d }

        d.startDate = min(d.startDate, first.timestamp)
        if closing { d.endDate = d.endDate ?? last.timestamp }
        d.durationMin = ((d.endDate ?? last.timestamp).timeIntervalSince(d.startDate)) / 60
        d.routePreview = RouteSimplifier.preview(sorted.map { RoutePoint(lat: $0.latitude, lon: $0.longitude) })
        d.startLatitude = first.latitude
        d.startLongitude = first.longitude
        d.endLatitude = last.latitude
        d.endLongitude = last.longitude

        // Vehicle-reported values (odometer, range, power) only exist on vehicle samples.
        let vehicle = sorted.filter { $0.source != .phone }
        let odo = vehicle.compactMap(\.odometerKm)
        if let a = odo.first, let b = odo.last { d.startOdometerKm = a; d.endOdometerKm = b }

        let gpsKm = GeoMath.pathLengthKm(sorted.map { ($0.latitude, $0.longitude) })
        if let a = d.startOdometerKm, let b = d.endOdometerKm, b - a >= 0.01 {
            d.distanceKm = b - a
        } else {
            d.distanceKm = gpsKm
        }

        let soc = vehicle.compactMap(\.batteryLevel)
        d.startBatteryLevel = soc.first
        d.endBatteryLevel = soc.last
        let range = vehicle.compactMap(\.ratedRangeKm)
        d.startRatedRangeKm = range.first
        d.endRatedRangeKm = range.last

        d.speedMaxKmh = sorted.compactMap(\.speedKmh).max()
        let power = vehicle.compactMap(\.powerKw)
        d.powerMaxKw = power.max()
        d.powerMinKw = power.min()
        d.outsideTempAvgC = average(vehicle.compactMap(\.outsideTempC))
        d.insideTempAvgC = average(vehicle.compactMap(\.insideTempC))

        // Prefer the densest elevation source (phone GPS) when available.
        let phoneElev = sorted.filter { $0.source == .phone }.compactMap(\.elevationM)
        let elev = phoneElev.count >= 10 ? phoneElev : sorted.compactMap(\.elevationM)
        let (up, down) = GeoMath.elevationChange(elev)
        d.ascentM = up
        d.descentM = down

        if let eff = efficiencyKwhPerKm, let a = d.startRatedRangeKm, let b = d.endRatedRangeKm {
            d.energyUsedKwh = max(0, (a - b) * eff)
        } else if power.count >= 2 {
            d.energyUsedKwh = integrateKwh(vehicle.compactMap { p in p.powerKw.map { (p.timestamp, $0) } }, maxGap: 120)
        }
        return d
    }

    /// Trapezoidal integration of kW samples; gaps longer than `maxGap` seconds are skipped.
    static func integrateKwh(_ samples: [(Date, Double)], maxGap: TimeInterval) -> Double? {
        guard samples.count >= 2 else { return nil }
        var kwh = 0.0
        for i in 1..<samples.count {
            let dt = samples[i].0.timeIntervalSince(samples[i - 1].0)
            guard dt > 0, dt <= maxGap else { continue }
            kwh += (samples[i].1 + samples[i - 1].1) / 2 * dt / 3600
        }
        return kwh
    }
}

public enum ChargeSummarizer {
    /// Samples further apart than this make wall-energy integration unreliable
    /// (common on iOS where background polling is opportunistic).
    public static let maxIntegrationGap: TimeInterval = 5 * 60

    /// - Parameter closing: false for a session still charging: totals so far, `endDate` stays nil.
    public static func summarize(_ session: ChargeSession, samples: [ChargeSample], tariff: Tariff?, closing: Bool = true) -> ChargeSession {
        var c = session
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        c.sampleCount = sorted.count
        guard let first = sorted.first, let last = sorted.last else { return c }

        c.startDate = min(c.startDate, first.timestamp)
        if closing { c.endDate = c.endDate ?? last.timestamp }
        c.durationMin = (c.endDate ?? last.timestamp).timeIntervalSince(c.startDate) / 60
        c.startBatteryLevel = first.batteryLevel
        c.endBatteryLevel = sorted.last(where: { $0.batteryLevel != nil })?.batteryLevel
        c.startRatedRangeKm = first.ratedRangeKm
        c.endRatedRangeKm = sorted.last(where: { $0.ratedRangeKm != nil })?.ratedRangeKm
        c.startIdealRangeKm = first.idealRangeKm
        c.endIdealRangeKm = sorted.last(where: { $0.idealRangeKm != nil })?.idealRangeKm
        c.powerMaxKw = sorted.compactMap(\.chargerPowerKw).max()
        c.outsideTempAvgC = average(sorted.compactMap(\.outsideTempC))
        c.fastChargerType = mode(sorted.filter { ($0.chargerPowerKw ?? 0) > 0 }.compactMap(\.fastChargerType))

        // charge_energy_added is a cumulative counter, so even 2 sparse samples give an exact
        // total. The final sample is sometimes reset to 0 after unplugging; use the max then.
        let added = sorted.compactMap(\.chargeEnergyAddedKwh)
        if let start = added.first {
            let end = (added.last.flatMap { $0 > 0 ? $0 : nil }) ?? added.max() ?? start
            let delta = end - start
            c.energyAddedKwh = delta >= 0 ? delta : nil
        }

        c.energyUsedKwh = energyUsed(sorted)
        c.cost = tariff.flatMap { cost(for: c, samples: sorted, tariff: $0) }
        return c
    }

    /// Integrates wall power. Uses phases × current × voltage when the reported charger
    /// power is too coarse (it's rounded to whole kW on AC).
    static func energyUsed(_ samples: [ChargeSample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let phases = inferPhases(samples)
        var kwh = 0.0
        var covered: TimeInterval = 0
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0, dt <= maxIntegrationGap else { continue }
            let kw: Double
            if let phases, let amps = a.chargerActualCurrent, let v = a.chargerVoltage, a.chargerPhases != nil, amps > 0, v > 0 {
                kw = Double(phases) * amps * v / 1000
            } else {
                kw = a.chargerPowerKw ?? 0
            }
            if kw >= 0 { kwh += kw * dt / 3600; covered += dt }
        }
        let total = samples.last!.timestamp.timeIntervalSince(samples.first!.timestamp)
        // Refuse to report a number if we only saw a fraction of the session.
        return total > 0 && covered / total >= 0.8 ? kwh : nil
    }

    static func inferPhases(_ samples: [ChargeSample]) -> Int? {
        let ratios = samples.compactMap { s -> Double? in
            guard let p = s.chargerPowerKw, let i = s.chargerActualCurrent, let v = s.chargerVoltage, i > 0, v > 0 else { return nil }
            return p * 1000 / (i * v)
        }
        guard let avg = average(ratios) else { return nil }
        let rounded = Int(avg.rounded())
        return (1...3).contains(rounded) ? rounded : nil
    }

    static func cost(for c: ChargeSession, samples: [ChargeSample], tariff t: Tariff) -> Double? {
        switch t.basis {
        case .perMinute:
            guard let m = c.durationMin else { return nil }
            return t.sessionFee + m * t.price(at: c.startDate)
        case .energyAdded, .energyUsed:
            let total = t.basis == .energyUsed ? (c.energyUsedKwh ?? c.energyAddedKwh) : c.energyAddedKwh
            guard let total else { return nil }
            guard !t.windows.isEmpty else { return t.sessionFee + total * t.pricePerUnit }
            // Time-of-use: spread energy over samples using the cumulative counter.
            var cost = 0.0, attributed = 0.0
            for i in 1..<max(samples.count, 1) {
                guard let a = samples[i - 1].chargeEnergyAddedKwh, let b = samples[i].chargeEnergyAddedKwh, b >= a else { continue }
                cost += (b - a) * t.price(at: samples[i - 1].timestamp)
                attributed += b - a
            }
            guard attributed > 0 else { return t.sessionFee + total * t.price(at: c.startDate) }
            return t.sessionFee + cost * (total / attributed)
        }
    }
}

func average(_ xs: [Double]) -> Double? {
    xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
}

func mode<T: Hashable>(_ xs: [T]) -> T? {
    var counts: [T: Int] = [:]
    for x in xs { counts[x, default: 0] += 1 }
    return counts.max { $0.value < $1.value }?.key
}
