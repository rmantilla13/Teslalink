import XCTest
@testable import TeslaLinkCore

final class CryptoTests: XCTestCase {
    func testSHA256() {
        let hex = SHA256Digest.portable(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPKCEChallengeMatchesRFC7636() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}

final class FleetDecodingTests: XCTestCase {
    func testVehicleDataDecodesAndConvertsUnits() throws {
        let json = """
        {"response":{"vin":"5YJ3E1EA7KF000001","state":"online","option_codes":"AD15,MDL3,PBSB",
          "charge_state":{"battery_level":80,"usable_battery_level":79,"battery_range":250.0,"charging_state":"Charging",
            "charge_energy_added":12.5,"charger_power":11,"charger_voltage":240,"charger_actual_current":48,"charger_phases":1,
            "timestamp":1700000000000},
          "drive_state":{"shift_state":null,"speed":null,"power":0,"latitude":37.0,"longitude":-122.0,"heading":90,"timestamp":1700000001000},
          "vehicle_state":{"odometer":10000.0,"locked":true,"sentry_mode":false,"df":0,"pf":0,"dr":0,"pr":0,"ft":0,"rt":1,
            "tpms_pressure_fl":2.9,"car_version":"2026.32.1 abc","software_update":{"status":"","download_perc":0}},
          "vehicle_config":{"car_type":"model3","trim_badging":"74d","exterior_color":"DeepBlue","wheel_type":"Pinwheel18"}}}
        """
        let env = try JSONDecoder().decode(FleetAPI.Envelope<FleetAPI.VehicleData>.self, from: Data(json.utf8))
        let s = VehicleSnapshot(try XCTUnwrap(env.response), receivedAt: Date())
        XCTAssertEqual(s.ratedRangeKm!, 402.336, accuracy: 0.001)
        XCTAssertEqual(s.odometerKm!, 16093.44, accuracy: 0.01)
        XCTAssertEqual(s.chargingState, .charging)
        XCTAssertNil(s.shiftState)
        XCTAssertEqual(s.speedKmh, 0)
        XCTAssertTrue(s.doorsOpen.rearTrunk)
        XCTAssertNil(s.softwareUpdateStatus)
        XCTAssertEqual(s.config?.model, .model3)
        XCTAssertEqual(s.config?.optionCodes, ["AD15", "MDL3", "PBSB"])
        XCTAssertEqual(s.timestamp, Date(timeIntervalSince1970: 1_700_000_001))
    }

    func testModelFromVIN() {
        XCTAssertEqual(VehicleModel(vin: "7SAYGDEE0PA000001"), .modelY)
        XCTAssertEqual(VehicleModel(vin: "5YJSA1E2XLF000001"), .modelS)
    }
}

final class StateMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func snap(_ minutes: Double, shift: ShiftState? = nil, charging: ChargingState? = .disconnected, odo: Double = 1000) -> VehicleSnapshot {
        var s = VehicleSnapshot(vin: "VIN", timestamp: t0.addingTimeInterval(minutes * 60))
        s.shiftState = shift
        s.chargingState = charging
        s.odometerKm = odo
        s.latitude = 37; s.longitude = -122
        s.powerKw = 0
        return s
    }

    func testIdleCarIsSuspendedThenSleeps() {
        var m = VehicleStateMachine()
        _ = m.handle(.status(.online, at: t0))
        XCTAssertEqual(m.nextPoll.request, .vehicleData)
        _ = m.handle(.vehicleData(snap(0)))
        XCTAssertEqual(m.state, .online)
        XCTAssertEqual(m.nextPoll.request, .vehicleData)
        _ = m.handle(.vehicleData(snap(16)))
        XCTAssertEqual(m.state, .suspended(since: t0.addingTimeInterval(16 * 60)))
        XCTAssertEqual(m.nextPoll.request, .statusOnly, "must stop calling vehicle_data so the car can sleep")
        let fx = m.handle(.status(.asleep, at: t0.addingTimeInterval(20 * 60)))
        XCTAssertEqual(m.state, .asleep)
        XCTAssertTrue(fx.contains(.stateChanged(.asleep, at: t0.addingTimeInterval(20 * 60))))
    }

    func testSentryBlocksSleep() {
        var m = VehicleStateMachine()
        var s = snap(0); s.sentryMode = true
        _ = m.handle(.vehicleData(s))
        s = snap(30); s.sentryMode = true
        _ = m.handle(.vehicleData(s))
        XCTAssertEqual(m.state, .online)
        XCTAssertEqual(m.sleepBlocker, .sentryMode)
    }

    func testSuspendedResumesAfterWindowIfStillOnline() {
        var m = VehicleStateMachine()
        _ = m.handle(.vehicleData(snap(0)))
        _ = m.handle(.vehicleData(snap(16)))
        _ = m.handle(.status(.online, at: t0.addingTimeInterval(20 * 60)))
        XCTAssertEqual(m.nextPoll.request, .statusOnly)
        _ = m.handle(.status(.online, at: t0.addingTimeInterval(38 * 60)))
        XCTAssertEqual(m.state, .online)
        XCTAssertEqual(m.nextPoll.request, .vehicleData)
    }

    func testDriveLifecycle() {
        var m = VehicleStateMachine()
        _ = m.handle(.vehicleData(snap(0)))
        let start = m.handle(.vehicleData(snap(1, shift: .drive)))
        XCTAssertEqual(m.state, .driving)
        XCTAssertTrue(start.contains { if case .startDrive = $0 { true } else { false } })
        XCTAssertEqual(m.nextPoll.after, LoggerSettings().drivingInterval)
        _ = m.handle(.vehicleData(snap(5, shift: .drive, odo: 1003)))
        let end = m.handle(.vehicleData(snap(10, shift: .park, odo: 1005)))
        XCTAssertEqual(m.state, .online)
        XCTAssertTrue(end.contains(.finishDrive(at: t0.addingTimeInterval(600))))
    }

    func testDriveSurvivesShortOfflineButClosesAfterTolerance() {
        var m = VehicleStateMachine()
        _ = m.handle(.vehicleData(snap(0, shift: .drive)))
        _ = m.handle(.status(.offline, at: t0.addingTimeInterval(5 * 60)))
        XCTAssertEqual(m.state, .driving)
        let fx = m.handle(.status(.offline, at: t0.addingTimeInterval(20 * 60)))
        XCTAssertTrue(fx.contains(.finishDrive(at: t0)))
        XCTAssertEqual(m.state, .offline(since: t0))
    }

    func testChargeLifecycleAndDriveClosesCharge() {
        var m = VehicleStateMachine()
        _ = m.handle(.vehicleData(snap(0, charging: .charging)))
        XCTAssertEqual(m.state, .charging)
        let fx = m.handle(.vehicleData(snap(60, charging: .complete)))
        XCTAssertTrue(fx.contains(.finishCharge(at: t0.addingTimeInterval(3600))))
        XCTAssertEqual(m.state, .online)
    }

    func testGapTriggersReconcile() {
        var m = VehicleStateMachine()
        _ = m.handle(.vehicleData(snap(0)))
        let fx = m.handle(.vehicleData(snap(120, odo: 1030)))
        XCTAssertTrue(fx.contains { if case .reconcileGap = $0 { true } else { false } })
    }
}

final class AnalyticsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testChargeEnergyFromSparseSamples() {
        let s = [
            ChargeSample(sessionID: 1, timestamp: t0, batteryLevel: 40, ratedRangeKm: 200, chargeEnergyAddedKwh: 0, chargerPowerKw: 11),
            ChargeSample(sessionID: 1, timestamp: t0.addingTimeInterval(3 * 3600), batteryLevel: 80, ratedRangeKm: 400, chargeEnergyAddedKwh: 30, chargerPowerKw: 11),
            ChargeSample(sessionID: 1, timestamp: t0.addingTimeInterval(3 * 3600 + 60), batteryLevel: 80, ratedRangeKm: 400, chargeEnergyAddedKwh: 0, chargerPowerKw: 0),
        ]
        let c = ChargeSummarizer.summarize(ChargeSession(vin: "V", startDate: t0), samples: s,
                                           tariff: Tariff(basis: .energyUsed, pricePerUnit: 0.30))
        XCTAssertEqual(c.energyAddedKwh, 30, "cumulative counter must survive the reset-to-zero after unplug")
        XCTAssertNil(c.energyUsedKwh, "3h sampling gap is too sparse to integrate")
        XCTAssertEqual(c.cost!, 9.0, accuracy: 1e-9, "falls back to energy added")
        XCTAssertEqual(c.durationMin!, 181, accuracy: 0.01)
    }

    func testChargeEnergyUsedDenseSampling() {
        let s = (0...60).map { i in
            ChargeSample(sessionID: 1, timestamp: t0.addingTimeInterval(Double(i) * 60), chargeEnergyAddedKwh: Double(i) * 0.16,
                         chargerPowerKw: 11, chargerVoltage: 240, chargerActualCurrent: 48, chargerPhases: 1)
        }
        let c = ChargeSummarizer.summarize(ChargeSession(vin: "V", startDate: t0), samples: s, tariff: nil)
        XCTAssertEqual(c.energyUsedKwh!, 11.52, accuracy: 0.01) // 240 V * 48 A for 1 h
        XCTAssertEqual(c.chargingEfficiency!, 9.6 / 11.52, accuracy: 0.01)
    }

    func testTimeOfUseCost() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let t = Tariff(basis: .energyAdded, pricePerUnit: 0.40, windows: [.init(startMinute: 22 * 60, endMinute: 6 * 60, pricePerUnit: 0.10)])
        XCTAssertEqual(t.price(at: Date(timeIntervalSince1970: 23 * 3600), calendar: cal), 0.10)
        XCTAssertEqual(t.price(at: Date(timeIntervalSince1970: 12 * 3600), calendar: cal), 0.40)
    }

    func testEfficiencyEstimatorFindsMode() {
        func charge(_ kwh: Double, _ km: Double) -> ChargeSession {
            var c = ChargeSession(vin: "V", startDate: t0)
            c.durationMin = 60; c.endBatteryLevel = 80; c.energyAddedKwh = kwh
            c.startRatedRangeKm = 100; c.endRatedRangeKm = 100 + km
            return c
        }
        let charges = [charge(15.3, 100), charge(30.6, 200), charge(7.65, 50), charge(20, 100)]
        let r = EfficiencyEstimator.estimate(from: charges)
        XCTAssertEqual(r?.kwhPerKm, 0.153)
        XCTAssertEqual(r?.confirmations, 3)
    }

    func testElevationDeadband() {
        let noisy: [Double] = [100, 101, 99, 100.5, 101, 110, 109, 111, 100]
        let (up, down) = GeoMath.elevationChange(noisy)
        XCTAssertEqual(up, 10)
        XCTAssertEqual(down, 10)
    }

    func testGapReconcilerFindsMissedDriveAndCharge() {
        var a = VehicleSnapshot(vin: "V", timestamp: t0); a.odometerKm = 1000; a.batteryLevel = 50
        var b = VehicleSnapshot(vin: "V", timestamp: t0.addingTimeInterval(7200)); b.odometerKm = 1025; b.batteryLevel = 70
        b.chargingState = .complete; b.chargeEnergyAddedKwh = 18
        let f = GapReconciler.reconcile(from: a, to: b)
        XCTAssertEqual(f.count, 2)
        guard case let .missedDrive(d) = f[0], case let .missedCharge(c) = f[1] else { return XCTFail() }
        XCTAssertEqual(d.distanceKm, 25)
        XCTAssertTrue(d.isInferred)
        XCTAssertEqual(c.energyAddedKwh, 18)
    }

    func testVampireDrain() {
        var d1 = Drive(vin: "V", startDate: t0); d1.endDate = t0.addingTimeInterval(600); d1.endRatedRangeKm = 300; d1.endBatteryLevel = 70
        var d2 = Drive(vin: "V", startDate: t0.addingTimeInterval(600 + 24 * 3600)); d2.endDate = d2.startDate.addingTimeInterval(600)
        d2.startRatedRangeKm = 294; d2.startBatteryLevel = 69
        let p = VampireDrainAnalyzer.periods(drives: [d1, d2], charges: [], efficiencyKwhPerKm: 0.15)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].rangeLostPerDayKm, 6, accuracy: 0.01)
        XCTAssertEqual(p[0].wattsAverage!, 37.5, accuracy: 0.01)
    }
}

// MARK: - End to end: logger + SQLite store + scripted car

actor ScriptedCar: VehicleDataSource {
    var script: [(OnlineState, VehicleSnapshot?)]
    var calls: [PollRequest] = []
    init(_ script: [(OnlineState, VehicleSnapshot?)]) { self.script = script }

    func status(vin: String) async throws -> OnlineState {
        calls.append(.statusOnly)
        return script.first?.0 ?? .asleep
    }

    func vehicleData(vin: String, now: Date) async throws -> VehicleSnapshot {
        calls.append(.vehicleData)
        guard !script.isEmpty, let s = script.removeFirst().1 else { throw FleetAPIError.vehicleUnavailable }
        return s
    }
}

final class LoggerEndToEndTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func point(_ min: Double, shift: ShiftState?, lat: Double, odo: Double, soc: Int, range: Double, charging: ChargingState = .disconnected, added: Double? = nil) -> VehicleSnapshot {
        var s = VehicleSnapshot(vin: "VIN", timestamp: t0.addingTimeInterval(min * 60))
        s.shiftState = shift; s.latitude = lat; s.longitude = -122; s.odometerKm = odo
        s.batteryLevel = soc; s.ratedRangeKm = range; s.powerKw = shift == nil ? 0 : 15
        s.speedKmh = shift == nil ? 0 : 60; s.chargingState = charging; s.chargeEnergyAddedKwh = added
        s.chargerPowerKw = charging == .charging ? 11 : 0
        return s
    }

    func testDriveThenChargeIsLogged() async throws {
        let store = try LogStore.inMemory()
        try await store.upsert(Vehicle(vin: "VIN", displayName: "Duo"))
        let home = try await store.save(Geofence(name: "Home", latitude: 37.10, longitude: -122, radiusM: 200,
                                                 tariff: Tariff(basis: .energyAdded, pricePerUnit: 0.25)))
        let car = ScriptedCar([
            (.online, point(0, shift: nil, lat: 37.00, odo: 1000, soc: 80, range: 400)),
            (.online, point(1, shift: .drive, lat: 37.00, odo: 1000, soc: 80, range: 400)),
            (.online, point(6, shift: .drive, lat: 37.05, odo: 1006, soc: 78, range: 392)),
            (.online, point(11, shift: .drive, lat: 37.10, odo: 1012, soc: 76, range: 386)),
            (.online, point(12, shift: .park, lat: 37.10, odo: 1012, soc: 76, range: 386)),
            (.online, point(13, shift: nil, lat: 37.10, odo: 1012, soc: 76, range: 386, charging: .charging, added: 0)),
            (.online, point(73, shift: nil, lat: 37.10, odo: 1012, soc: 90, range: 460, charging: .charging, added: 11)),
            (.online, point(80, shift: nil, lat: 37.10, odo: 1012, soc: 90, range: 460, charging: .complete, added: 11)),
        ])
        let logger = await VehicleLogger(vin: "VIN", source: car, store: store)
        var now = t0
        for _ in 0..<9 { await logger.poll(now: now, force: true); now += 60 }

        let drives = try await store.drives(vin: "VIN")
        XCTAssertEqual(drives.count, 1)
        let d = try XCTUnwrap(drives.first)
        XCTAssertEqual(d.distanceKm!, 12, accuracy: 0.001)
        XCTAssertEqual(d.startBatteryLevel, 80)
        XCTAssertEqual(d.endBatteryLevel, 76)
        XCTAssertEqual(d.endGeofenceID, home.id)
        XCTAssertFalse(d.isOpen)

        let charges = try await store.charges(vin: "VIN")
        XCTAssertEqual(charges.count, 1)
        let c = try XCTUnwrap(charges.first)
        XCTAssertEqual(c.energyAddedKwh, 11)
        XCTAssertEqual(c.cost!, 2.75, accuracy: 1e-9)
        XCTAssertEqual(c.geofenceID, home.id)
        XCTAssertEqual(c.endBatteryLevel, 90)

        let kinds = try await store.states(vin: "VIN").map(\.kind)
        XCTAssertEqual(kinds, [.online, .driving, .online, .charging, .online])
    }

    func testPhoneGPSIsAttachedToDrive() async throws {
        let store = try LogStore.inMemory()
        try await store.upsert(Vehicle(vin: "VIN", displayName: "Duo"))
        let car = ScriptedCar([
            (.online, point(0, shift: .drive, lat: 37.00, odo: 1000, soc: 80, range: 400)),
            (.online, point(10, shift: .park, lat: 37.02, odo: 1003, soc: 79, range: 397)),
        ])
        let logger = await VehicleLogger(vin: "VIN", source: car, store: store)
        await logger.poll(now: t0, force: true) // first contact is always a non-waking status check
        await logger.poll(now: t0, force: true)
        let phone = (1...9).map { i in Position(vin: "", timestamp: t0.addingTimeInterval(Double(i) * 60), latitude: 37 + Double(i) * 0.002,
                                                 longitude: -122, elevationM: 10 + Double(i) * 5, speedKmh: 40, source: .phone) }
        await logger.ingestPhoneLocations(phone)
        await logger.poll(now: t0 + 600, force: true)
        let all = try await store.drives(vin: "VIN")
        let d = try XCTUnwrap(all.first)
        let positions = try await store.positions(driveID: d.id!)
        XCTAssertEqual(positions.count, 11)
        XCTAssertEqual(positions.filter { $0.source == .phone }.count, 9)
        XCTAssertEqual(d.ascentM!, 40, accuracy: 0.001, "phone altitude is used for elevation")
    }

    func testCheckpointRestoresStateAcrossLaunches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("log.sqlite").path
        do {
            let store = try LogStore(path: path)
            let car = ScriptedCar([(.online, point(0, shift: .drive, lat: 37, odo: 1000, soc: 80, range: 400))])
            let logger = await VehicleLogger(vin: "VIN", source: car, store: store)
            await logger.poll(now: t0, force: true)
            await logger.poll(now: t0, force: true)
            let s = await logger.state
            XCTAssertEqual(s, .driving)
        }
        let store = try LogStore(path: path)
        let logger = await VehicleLogger(vin: "VIN", source: ScriptedCar([]), store: store)
        let s = await logger.state
        XCTAssertEqual(s, .driving, "app relaunched in background mid-drive keeps the open drive")
        let open = try await store.openDrive(vin: "VIN")
        XCTAssertNotNil(open)
    }
}

final class PhoneMatchAndImageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testPhoneTrackRejectedWhenFarFromCar() {
        let car = (0..<5).map { Position(vin: "V", timestamp: t0 + Double($0) * 60, latitude: 37 + Double($0) * 0.01, longitude: -122, source: .vehicle) }
        let near = (0..<5).map { Position(vin: "V", timestamp: t0 + Double($0) * 60 + 5, latitude: 37 + Double($0) * 0.01, longitude: -122.001, source: .phone) }
        let far = near.map { var p = $0; p.longitude = -121.5; return p }
        XCTAssertTrue(PhoneTrackMatcher.phoneWasInCar(car + near))
        XCTAssertFalse(PhoneTrackMatcher.phoneWasInCar(car + far))
    }

    func testCompositorURLUsesPaintAndWheels() throws {
        let url = try XCTUnwrap(VehicleImage.url(for: VehicleConfig(model: .model3, exteriorColor: "DeepBlue", wheelType: "Stiletto19", optionCodes: ["MT337", "PBSB"])))
        let options = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "options" }?.value
        XCTAssertEqual(options, "$MT337,$PPSB,$W39B")
        XCTAssertTrue(url.absoluteString.contains("model=m3"))
    }
}

final class LiveAndPreviewTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testRoutePreviewIsBoundedAndKeepsEnds() throws {
        let pts = (0..<500).map { i in RoutePoint(lat: 37 + Double(i) * 0.0005, lon: -122 + sin(Double(i) / 20) * 0.01) }
        let p = try XCTUnwrap(RouteSimplifier.preview(pts))
        XCTAssertLessThanOrEqual(p.count, 32)
        XCTAssertGreaterThan(p.count, 4)
        XCTAssertEqual(p.first, pts.first)
        XCTAssertEqual(p.last, pts.last)
    }

    func testOpenDriveAndChargeShowRunningTotals() async throws {
        let store = try LogStore.inMemory()
        try await store.upsert(Vehicle(vin: "VIN", displayName: "Duo"))
        func s(_ m: Double, shift: ShiftState?, odo: Double, charging: ChargingState = .disconnected, added: Double? = nil) -> VehicleSnapshot {
            var x = VehicleSnapshot(vin: "VIN", timestamp: t0.addingTimeInterval(m * 60))
            x.shiftState = shift; x.odometerKm = odo; x.latitude = 37 + odo / 1000; x.longitude = -122
            x.batteryLevel = 70; x.ratedRangeKm = 350; x.powerKw = 0; x.chargingState = charging
            x.chargeEnergyAddedKwh = added; x.chargerPowerKw = charging == .charging ? 50 : 0
            return x
        }
        let car = ScriptedCar([
            (.online, s(0, shift: .drive, odo: 1000)),
            (.online, s(5, shift: .drive, odo: 1004)),
            (.online, s(10, shift: .park, odo: 1007)),
            (.online, s(11, shift: nil, odo: 1007, charging: .charging, added: 0)),
            (.online, s(16, shift: nil, odo: 1007, charging: .charging, added: 4.2)),
        ])
        let logger = await VehicleLogger(vin: "VIN", source: car, store: store)
        await logger.poll(now: t0, force: true)          // status
        await logger.poll(now: t0, force: true)          // drive starts
        await logger.poll(now: t0 + 300, force: true)    // still driving
        let open = try await store.openDrive(vin: "VIN")
        XCTAssertNil(open?.endDate, "an in-progress drive stays open")
        XCTAssertEqual(open?.distanceKm ?? 0, 4, accuracy: 0.001, "distance so far is kept current")
        await logger.poll(now: t0 + 600, force: true)    // park
        await logger.poll(now: t0 + 660, force: true)    // charge starts
        await logger.poll(now: t0 + 960, force: true)    // charging
        let charge = try await store.openCharge(vin: "VIN")
        XCTAssertNil(charge?.endDate)
        XCTAssertEqual(charge?.energyAddedKwh, 4.2, "energy so far for the live screen")
        let drive = try await store.drives(vin: "VIN").first
        XCTAssertNotNil(drive?.routePreview)
    }
}

final class DemoDataTests: XCTestCase {
    func testDemoHistoryIsPlausible() async throws {
        let store = try LogStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try await DemoData.seed(store, days: 30, now: now)
        let drives = try await store.drives(vin: DemoData.vin)
        let charges = try await store.charges(vin: DemoData.vin)
        XCTAssertGreaterThan(drives.count, 25)
        XCTAssertGreaterThan(charges.count, 3)
        for d in drives {
            XCTAssertFalse(d.isOpen)
            XCTAssertGreaterThan(d.distanceKm ?? 0, 1)
            XCTAssertNotNil(d.routePreview)
            XCTAssertLessThan(d.endDate!, now)
            let e = try XCTUnwrap(d.efficiencyWhPerKm)
            XCTAssert((100...300).contains(e), "efficiency \(e) Wh/km")
        }
        for c in charges {
            XCTAssertGreaterThan(c.energyAddedKwh ?? 0, 1)
            XCTAssertNotNil(c.endDate)
        }
        XCTAssertTrue(charges.contains { $0.cost != nil }, "home charges are priced")
        // Seeding twice is a no-op.
        try await DemoData.seed(store, days: 30, now: now)
        let again = try await store.drives(vin: DemoData.vin).count
        XCTAssertEqual(again, drives.count)
    }

    /// "Explore with a demo car" shows dashes until seeding finishes, so it has to be quick
    /// against a real file (WAL) store, not just in memory.
    func testSeedingAFileStoreIsQuick() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let store = try LogStore(path: url.path)
        let started = Date()
        try await DemoData.seed(store, days: 30, now: Date(timeIntervalSince1970: 1_790_000_000))
        let elapsed = Date().timeIntervalSince(started)
        print("Demo seeding took \(elapsed) s")
        XCTAssertLessThan(elapsed, 3, "demo seeding took \(elapsed) s")
    }

    func testDemoCarChargesThroughTheLogger() async throws {
        let store = try LogStore.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        try await DemoData.seed(store, days: 3, now: t0)
        let car = await DemoCar(store: store, now: t0)
        let logger = await VehicleLogger(vin: DemoData.vin, source: car, store: store)
        await logger.poll(now: t0, force: true)
        await logger.poll(now: t0 + 5, force: true)
        let s = await logger.state
        XCTAssertEqual(s, .charging)
        for i in 2...40 { await logger.poll(now: t0 + Double(i * 5), force: true) }
        let finished = try await store.charges(vin: DemoData.vin).first
        XCTAssertNotNil(finished?.endDate, "the demo charge completes")
        XCTAssertGreaterThan(finished?.energyAddedKwh ?? 0, 10)
        XCTAssertEqual(finished?.endBatteryLevel, 80, "it stops at the 80% limit")
        XCTAssertLessThan(finished?.startBatteryLevel ?? 100, 60, "and starts low enough to watch it charge")
    }
}
