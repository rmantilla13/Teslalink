import Foundation

/// Sample data so the app can be explored (and screenshotted) without a Tesla account.
/// Everything is generated deterministically from a seed, through the same summarizers
/// the real logger uses, so the numbers are internally consistent.
public enum DemoData {
    public static let vin = "DEMO0000000000001"
    public static let home = (lat: 37.3947, lon: -122.0790)
    public static let office = (lat: 37.4419, lon: -122.1430)

    public static var vehicle: Vehicle {
        Vehicle(vin: vin, displayName: "Duo",
                config: VehicleConfig(model: .modelY, trimBadging: "74d", exteriorColor: "DeepBlue", wheelType: "Gemini19"),
                efficiencyKwhPerKm: 0.153)
    }

    /// Fills an empty store with `days` of drives and charges ending at `now`.
    public static func seed(_ store: LogStore, days: Int = 30, now: Date = Date()) async throws {
        guard try await store.vehicle(vin: vin) == nil else { return }
        try await store.upsert(vehicle)
        let homeFence = try await store.save(Geofence(name: "Home", latitude: home.lat, longitude: home.lon, radiusM: 120,
                                                      tariff: Tariff(basis: .energyUsed, pricePerUnit: 0.32,
                                                                     windows: [.init(startMinute: 22 * 60, endMinute: 6 * 60, pricePerUnit: 0.12)])))
        let officeFence = try await store.save(Geofence(name: "Office", latitude: office.lat, longitude: office.lon, radiusM: 150))

        var rng = SeededRandom(seed: 42)
        let cal = Calendar(identifier: .gregorian)
        var odometer = 18_000.0
        var soc = 78.0
        let start = cal.startOfDay(for: now.addingTimeInterval(-Double(days) * 86_400))

        for day in 0..<days {
            let dayStart = start.addingTimeInterval(Double(day) * 86_400)
            let weekday = cal.component(.weekday, from: dayStart)
            let workday = (2...6).contains(weekday)
            let temp = 6 + 10 * sin(Double(day) / 9) + rng.next(in: -3...3)
            var trips: [(from: (lat: Double, lon: Double), to: (lat: Double, lon: Double), hour: Double, fenceA: RecordID?, fenceB: RecordID?)] = []
            if workday {
                trips.append((home, office, 8 + rng.next(in: 0...0.6), homeFence.id, officeFence.id))
                trips.append((office, home, 17.5 + rng.next(in: 0...1), officeFence.id, homeFence.id))
            } else if rng.next(in: 0...1) > 0.3 {
                let errand = (lat: home.lat + rng.next(in: -0.05...0.05), lon: home.lon + rng.next(in: -0.06...0.06))
                trips.append((home, errand, 11 + rng.next(in: 0...2), homeFence.id, nil))
                trips.append((errand, home, 13.5 + rng.next(in: 0...2), nil, homeFence.id))
            }
            for t in trips {
                let begin = dayStart.addingTimeInterval(t.hour * 3600)
                guard begin < now.addingTimeInterval(-3600) else { continue }
                let (drive, positions) = makeDrive(from: t.from, to: t.to, start: begin, odometer: odometer, soc: soc, temp: temp, rng: &rng)
                var d = try await store.save(drive)
                try await store.insert(positions.map { var p = $0; p.driveID = d.id; return p })
                d = DriveSummarizer.summarize(d, positions: positions, efficiencyKwhPerKm: vehicle.efficiencyKwhPerKm)
                d.startGeofenceID = t.fenceA
                d.endGeofenceID = t.fenceB
                try await store.save(d)
                odometer = d.endOdometerKm ?? odometer
                soc = Double(d.endBatteryLevel ?? Int(soc))
            }
            // Charge at home overnight when below 55%, occasionally at a fast charger on weekends.
            let night = dayStart.addingTimeInterval(22.5 * 3600)
            if soc < 55, night < now.addingTimeInterval(-8 * 3600) {
                soc = try await makeCharge(store, start: night, fromSoc: soc, toSoc: 80, dc: false, fence: homeFence, temp: temp)
            } else if !workday, soc < 65, rng.next(in: 0...1) > 0.6, night < now.addingTimeInterval(-3600) {
                soc = try await makeCharge(store, start: dayStart.addingTimeInterval(15 * 3600), fromSoc: soc, toSoc: 80, dc: true, fence: nil, temp: temp)
            }
        }
        try await store.set(DemoCar.State(odometerKm: odometer, soc: soc), for: "demo.car")
    }

    static func makeDrive(from a: (lat: Double, lon: Double), to b: (lat: Double, lon: Double), start: Date,
                          odometer: Double, soc: Double, temp: Double, rng: inout SeededRandom) -> (Drive, [Position]) {
        let straightKm = GeoMath.distanceMeters(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon) / 1000
        let roadKm = max(1.5, straightKm * 1.3)
        let steps = max(12, Int(roadKm * 6))
        var positions: [Position] = []
        var t = start, km = 0.0
        let ratedPerKm = 1.18 + max(0, (15 - temp)) * 0.012
        let phase = rng.next(in: 0...6)
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let wobble = sin(f * .pi * 3 + phase) * 0.004 * (1 - abs(0.5 - f) * 2)
            let lat = a.lat + (b.lat - a.lat) * f + wobble
            let lon = a.lon + (b.lon - a.lon) * f - wobble
            let cruise = roadKm > 15 ? 95.0 : 55.0
            let speed = i == 0 || i == steps ? 0 : max(8, cruise * sin(.pi * f).squareRoot() + rng.next(in: -10...10))
            if i > 0 {
                let segKm = roadKm / Double(steps)
                km += segKm
                t = t.addingTimeInterval(segKm / max(speed, 15) * 3600)
            }
            let power = speed == 0 ? 0 : speed * 0.18 + rng.next(in: -12...22)
            positions.append(Position(vin: vin, timestamp: t, latitude: lat, longitude: lon,
                                      elevationM: 30 + 25 * sin(f * .pi * 2 + phase), speedKmh: speed, powerKw: power,
                                      odometerKm: odometer + km, batteryLevel: Int((soc - km * ratedPerKm / 4.8).rounded()),
                                      ratedRangeKm: soc * 4.8 - km * ratedPerKm, outsideTempC: temp, insideTempC: 21))
        }
        var d = Drive(vin: vin, startDate: start)
        d.endDate = positions.last?.timestamp
        return (d, positions)
    }

    static func makeCharge(_ store: LogStore, start: Date, fromSoc: Double, toSoc: Double, dc: Bool, fence: Geofence?, temp: Double) async throws -> Double {
        var c = ChargeSession(vin: vin, startDate: start)
        c.geofenceID = fence?.id
        c.latitude = fence?.latitude ?? home.lat + 0.08
        c.longitude = fence?.longitude ?? home.lon - 0.1
        c = try await store.save(c)
        guard let id = c.id else { return fromSoc }
        var soc = fromSoc, added = 0.0, t = start
        var samples: [ChargeSample] = []
        let step: TimeInterval = dc ? 30 : 60
        while soc < toSoc {
            let kw = dc ? max(45, min(250, 250 - max(0, soc - 22) * 3.4)) : 11
            let kwh = kw * step / 3600
            added += kwh * (dc ? 1 : 0.9)
            soc += kwh * 0.9 / 0.75
            samples.append(ChargeSample(sessionID: id, timestamp: t, batteryLevel: Int(soc), usableBatteryLevel: Int(soc) - 1,
                                        ratedRangeKm: soc * 4.8, idealRangeKm: soc * 5.0, chargeEnergyAddedKwh: added,
                                        chargerPowerKw: kw.rounded(), chargerVoltage: dc ? 398 : 240,
                                        chargerActualCurrent: dc ? kw * 1000 / 398 : 48, chargerPhases: dc ? nil : 1,
                                        outsideTempC: temp, fastChargerType: dc ? "Supercharger" : nil))
            t = t.addingTimeInterval(step)
        }
        for s in samples { try await store.insert(s) }
        c.endDate = t
        c = ChargeSummarizer.summarize(c, samples: samples, tariff: fence?.tariff)
        try await store.save(c)
        return soc
    }
}

/// A simulated car that is plugged in and charging when the demo starts, then rests.
public actor DemoCar: VehicleDataSource {
    public struct State: Codable, Sendable { var odometerKm: Double; var soc: Double }

    private let startedAt: Date
    private var state: State

    public init(store: LogStore, now: Date = Date()) async {
        startedAt = now
        state = (try? await store.get(State.self, for: "demo.car")) ?? State(odometerKm: 18_400, soc: 52)
    }

    public func status(vin: String) async throws -> OnlineState { .online }

    public func vehicleData(vin: String, now: Date) async throws -> VehicleSnapshot {
        // Accelerated: one real second is one simulated minute. The car is plugged in at home
        // when the demo starts and charges at 11 kW from at most 55% up to its 80% limit
        // (about two minutes), then rests at the limit with the charge complete.
        let minutes = max(0, now.timeIntervalSince(startedAt))
        let startSoc = min(state.soc, 55)
        let socPerMinute = 11 * 0.9 / 75 * 100 / 60   // 11 kW, 90% into the pack, ~75 kWh usable
        let soc = min(80, startSoc + minutes * socPerMinute)
        let charging = soc < 80
        let added = (soc - startSoc) * 0.75
        var s = VehicleSnapshot(vin: vin, timestamp: now)
        s.latitude = DemoData.home.lat; s.longitude = DemoData.home.lon; s.heading = 90
        s.odometerKm = state.odometerKm
        s.batteryLevel = Int(soc); s.usableBatteryLevel = Int(soc) - 1
        s.ratedRangeKm = soc * 4.8; s.idealRangeKm = soc * 5; s.estimatedRangeKm = soc * 4.4
        s.chargingState = charging ? .charging : .complete
        s.chargeLimitSoc = 80
        s.chargeEnergyAddedKwh = added
        s.chargerPowerKw = charging ? 11 : 0
        s.chargerVoltage = charging ? 240 : 0
        s.chargerActualCurrent = charging ? 48 : 0
        s.chargerPhases = charging ? 1 : nil
        s.fastChargerPresent = false
        s.minutesToFullCharge = charging ? Int(((80 - soc) / socPerMinute).rounded(.up)) : 0
        s.chargePortDoorOpen = true
        s.outsideTempC = 14; s.insideTempC = 21; s.isClimateOn = false
        s.locked = true; s.sentryMode = true; s.shiftState = nil; s.speedKmh = 0; s.powerKw = 0
        s.tirePressureBar = TirePressures(frontLeft: 2.9, frontRight: 2.9, rearLeft: 2.4, rearRight: 2.9)
        s.softwareVersion = "2026.38.4"
        s.config = DemoData.vehicle.config
        return s
    }
}

/// Small deterministic PRNG (SplitMix64) so demo data is the same on every device.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * Double(nextUInt() >> 11) / Double(1 << 53)
    }
}
