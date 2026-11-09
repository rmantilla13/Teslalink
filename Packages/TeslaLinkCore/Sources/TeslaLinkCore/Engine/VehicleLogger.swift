import Foundation

/// Anything that can answer "how's the car?" — the Fleet API today; BLE or a mock tomorrow.
public protocol VehicleDataSource: Sendable {
    func status(vin: String) async throws -> OnlineState
    func vehicleData(vin: String, now: Date) async throws -> VehicleSnapshot
}

extension FleetAPIClient: VehicleDataSource {}

/// Runs the state machine for one car against a data source and writes the log.
///
/// iOS decides when the app may run, so this is designed to be "ticked": call `poll()`
/// whenever you get execution time (foreground timer, background refresh, location wake)
/// and it does the right next request, then tells you when it would like to run again.
public actor VehicleLogger {
    public let vin: String
    private let source: VehicleDataSource
    private let store: LogStore
    private var machine: VehicleStateMachine
    private var dueAt: Date = .distantPast
    public private(set) var latest: VehicleSnapshot?
    public private(set) var lastError: String?

    private var checkpointKey: String { "logger.\(vin)" }

    struct Checkpoint: Codable {
        var state: LoggerState
        var snapshot: VehicleSnapshot?
    }

    public init(vin: String, source: VehicleDataSource, store: LogStore, settings: LoggerSettings = LoggerSettings()) async {
        self.vin = vin
        self.source = source
        self.store = store
        let cp = try? await store.get(Checkpoint.self, for: "logger.\(vin)")
        machine = VehicleStateMachine(settings: settings, restoring: cp?.state ?? .start, lastSnapshot: cp?.snapshot)
        latest = cp?.snapshot
    }

    public var state: LoggerState { machine.state }
    public var sleepBlocker: SleepBlocker? { machine.sleepBlocker }
    public var nextPoll: PollPlan { machine.nextPoll }
    public var nextDueDate: Date { dueAt }

    public func updateSettings(_ s: LoggerSettings) { machine.settings = s }

    /// The user opened the app: don't hold back on polling.
    public func userBecameActive(now: Date = Date()) async {
        await apply(machine.handle(.userActive(at: now)))
        dueAt = min(dueAt, now)
    }

    /// Performs the next request if it's due (or `force`), returns the plan for the one after.
    @discardableResult
    public func poll(now: Date = Date(), force: Bool = false) async -> PollPlan {
        guard force || now >= dueAt else { return machine.nextPoll }
        let event: LoggerEvent
        var retryAfter: TimeInterval?
        do {
            switch machine.nextPoll.request {
            case .statusOnly:
                event = .status(try await source.status(vin: vin), at: now)
            case .vehicleData:
                do {
                    let s = try await source.vehicleData(vin: vin, now: now)
                    latest = s
                    event = .vehicleData(s)
                } catch FleetAPIError.vehicleUnavailable {
                    // Fell asleep / went offline between the status check and the data request.
                    event = .status(try await source.status(vin: vin), at: now)
                }
            }
            lastError = nil
        } catch {
            if case let FleetAPIError.rateLimited(after) = error { retryAfter = after }
            lastError = String(describing: error)
            event = .fetchFailed(at: now)
        }
        await apply(machine.handle(event))
        // Rate limited: respect the server's Retry-After.
        dueAt = now.addingTimeInterval(max(retryAfter ?? 0, machine.nextPoll.after))
        try? await store.set(Checkpoint(state: machine.state, snapshot: machine.lastSnapshot), for: checkpointKey)
        return machine.nextPoll
    }

    /// Dense GPS from the phone while the car is being driven (the phone is in the car).
    /// Stored immediately; attached to the drive when it is closed.
    public func ingestPhoneLocations(_ points: [Position]) async {
        let open = try? await store.openDrive(vin: vin)
        let tagged = points.map { p -> Position in
            var p = p
            p.vin = vin
            p.source = .phone
            p.driveID = open?.id
            return p
        }
        try? await store.insert(tagged)
    }

    // MARK: Effects

    private func apply(_ effects: [LoggerEffect]) async {
        for e in effects {
            do { try await apply(e) } catch { lastError = "storage: \(error)" }
        }
    }

    private func apply(_ effect: LoggerEffect) async throws {
        switch effect {
        case let .stateChanged(kind, at):
            try await store.beginState(kind, vin: vin, at: at)

        case let .startDrive(s):
            var d = Drive(vin: vin, startDate: s.timestamp)
            d.startLatitude = s.latitude; d.startLongitude = s.longitude
            d.startOdometerKm = s.odometerKm
            d.startBatteryLevel = s.batteryLevel
            d.startRatedRangeKm = s.ratedRangeKm
            if let lat = s.latitude, let lon = s.longitude {
                d.startGeofenceID = GeoMath.nearestGeofence(try await store.geofences(), latitude: lat, longitude: lon)?.id
            }
            try await store.save(d)

        case let .recordDrivePosition(s):
            let open = try await store.openDrive(vin: vin)
            if let p = Position(snapshot: s, driveID: open?.id) { try await store.insert(p) }
            // Keep the open drive's running totals current for the live UI.
            if var d = open, let id = d.id {
                let eff = try await store.vehicle(vin: vin)?.efficiencyKwhPerKm
                d = DriveSummarizer.summarize(d, positions: try await store.positions(driveID: id), efficiencyKwhPerKm: eff, closing: false)
                try await store.save(d)
            }

        case let .finishDrive(at):
            guard var d = try await store.openDrive(vin: vin), let id = d.id else { return }
            try await store.attachPhonePositions(vin: vin, driveID: id, from: d.startDate.addingTimeInterval(-120), to: at)
            var positions = try await store.positions(driveID: id)
            if !PhoneTrackMatcher.phoneWasInCar(positions) {
                try await store.detachPhonePositions(driveID: id)
                positions = positions.filter { $0.source != .phone }
            }
            let eff = try await store.vehicle(vin: vin)?.efficiencyKwhPerKm
            d.endDate = at
            d = DriveSummarizer.summarize(d, positions: positions, efficiencyKwhPerKm: eff)
            if positions.count < 2 || (d.distanceKm ?? 0) < 0.01 {
                try await store.deleteDrive(id: id)
                return
            }
            let fences = try await store.geofences()
            if let lat = d.endLatitude, let lon = d.endLongitude {
                d.endGeofenceID = GeoMath.nearestGeofence(fences, latitude: lat, longitude: lon)?.id
            }
            try await store.save(d)

        case let .startCharge(s):
            var c = ChargeSession(vin: vin, startDate: s.timestamp)
            c.latitude = s.latitude; c.longitude = s.longitude
            c.startBatteryLevel = s.batteryLevel
            c.startRatedRangeKm = s.ratedRangeKm
            if let lat = s.latitude, let lon = s.longitude {
                c.geofenceID = GeoMath.nearestGeofence(try await store.geofences(), latitude: lat, longitude: lon)?.id
            }
            try await store.save(c)

        case let .recordChargeSample(s):
            guard var c = try await store.openCharge(vin: vin), let id = c.id else { return }
            try await store.insert(ChargeSample(snapshot: s, sessionID: id))
            // Energy, power and cost so far, for the live charging screen.
            let tariff = try await store.geofences().first { $0.id == c.geofenceID }?.tariff
            c = ChargeSummarizer.summarize(c, samples: try await store.samples(sessionID: id), tariff: tariff, closing: false)
            try await store.save(c)

        case let .finishCharge(at):
            guard var c = try await store.openCharge(vin: vin), let id = c.id else { return }
            let samples = try await store.samples(sessionID: id)
            let tariff = try await store.geofences().first { $0.id == c.geofenceID }?.tariff
            c.endDate = at
            c = ChargeSummarizer.summarize(c, samples: samples, tariff: tariff)
            try await store.save(c)
            try await recalculateEfficiency()

        case let .startUpdate(version, at):
            try await store.beginUpdate(vin: vin, version: version, at: at)
        case let .finishUpdate(at):
            try await store.finishUpdate(vin: vin, at: at)

        case let .recordParkedPosition(s):
            if let p = Position(snapshot: s, driveID: nil) { try await store.insert(p) }

        case let .reconcileGap(a, b):
            let fences = try await store.geofences()
            for finding in GapReconciler.reconcile(from: a, to: b) {
                switch finding {
                case var .missedDrive(d):
                    if let lat = d.startLatitude, let lon = d.startLongitude { d.startGeofenceID = GeoMath.nearestGeofence(fences, latitude: lat, longitude: lon)?.id }
                    if let lat = d.endLatitude, let lon = d.endLongitude { d.endGeofenceID = GeoMath.nearestGeofence(fences, latitude: lat, longitude: lon)?.id }
                    if let eff = try await store.vehicle(vin: vin)?.efficiencyKwhPerKm, let r0 = d.startRatedRangeKm, let r1 = d.endRatedRangeKm {
                        d.energyUsedKwh = max(0, (r0 - r1) * eff)
                    }
                    let saved = try await store.save(d)
                    // Phone GPS may have captured this drive even though the API didn't.
                    if let id = saved.id {
                        try await store.attachPhonePositions(vin: vin, driveID: id, from: a.timestamp, to: b.timestamp)
                    }
                case var .missedCharge(c):
                    if let lat = c.latitude, let lon = c.longitude { c.geofenceID = GeoMath.nearestGeofence(fences, latitude: lat, longitude: lon)?.id }
                    try await store.save(c)
                }
            }
        }
    }

    private func recalculateEfficiency() async throws {
        let charges = try await store.charges(vin: vin)
        guard let (factor, _) = EfficiencyEstimator.estimate(from: charges),
              var v = try await store.vehicle(vin: vin), v.efficiencyKwhPerKm != factor else { return }
        v.efficiencyKwhPerKm = factor
        try await store.upsert(v)
    }
}
