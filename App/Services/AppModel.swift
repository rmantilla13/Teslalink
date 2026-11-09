import BackgroundTasks
import Foundation
import Observation
import TeslaLinkCore
import UserNotifications

struct LiveStatus: Equatable {
    var snapshot: VehicleSnapshot?
    var state: LoggerState = .start
    var blocker: SleepBlocker?
    var lastError: String?
    var nextPoll: Date?
}

/// App-wide state: owns the database, auth, and one logger per car.
@MainActor
@Observable
final class AppModel {
    static let refreshTaskID = "com.teslalink.refresh"

    var settings: AppSettings { didSet { settings.save(); applySettings(oldValue) } }
    private(set) var vehicles: [Vehicle] = []
    private(set) var live: [String: LiveStatus] = [:]
    /// Bumped whenever new rows may exist; list views observe it to reload.
    private(set) var dataVersion = 0
    private(set) var isSignedIn = false
    var errorMessage: String?

    let store: LogStore
    private(set) var auth: FleetAuth?
    private var client: FleetAPIClient?
    private var loggers: [String: VehicleLogger] = [:]
    private let tokens = KeychainTokenStore()
    private var loopTask: Task<Void, Never>?
    private(set) var isForeground = false
    let phone = PhoneDriveTracker()
    private let addresses: AddressResolver
    private var lastAddressRun = Date.distantPast

    init() {
        settings = AppSettings.load()
        let url = URL.applicationSupportDirectory.appending(path: "TeslaLink", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dbURL = url.appending(path: "log.sqlite")
        do {
            store = try LogStore(path: dbURL.path)
        } catch {
            fatalError("Could not open database: \(error)")
        }
        addresses = AddressResolver(store: store)
        phone.onPositions = { [weak self] points in
            Task { await self?.ingestPhone(points) }
        }
        phone.onMovementStarted = { [weak self] in
            Task { await self?.pollAll(force: true) }
            self?.ensureLoop()
        }
        configureAPI()
        Task { await bootstrap() }
    }

    var selectedVehicle: Vehicle? {
        vehicles.first { $0.vin == settings.selectedVIN } ?? vehicles.first
    }

    func status(for vin: String) -> LiveStatus { live[vin] ?? LiveStatus() }

    // MARK: Setup

    private func configureAPI() {
        guard let config = settings.fleetConfig else {
            auth = nil; client = nil; isSignedIn = false
            return
        }
        let auth = FleetAuth(config: config, store: tokens)
        self.auth = auth
        client = FleetAPIClient(region: settings.region, tokens: auth)
        isSignedIn = auth.isSignedIn
    }

    private func applySettings(_ old: AppSettings) {
        if old.region != settings.region || old.clientIDOverride != settings.clientIDOverride
            || old.clientSecretOverride != settings.clientSecretOverride || old.redirectURIOverride != settings.redirectURIOverride {
            configureAPI()
            loggers = [:]
            Task { await bootstrap() }
        }
        if old.logger != settings.logger {
            for l in loggers.values { Task { await l.updateSettings(settings.logger) } }
        }
        if old.usePhoneGPS != settings.usePhoneGPS {
            settings.usePhoneGPS ? phone.start() : phone.stop()
        }
    }

    private func bootstrap() async {
        vehicles = (try? await store.vehicles()) ?? []
        if settings.usePhoneGPS { phone.start() }
        guard isSignedIn else { return }
        await refreshVehicleList()
        ensureLoop()
    }

    func refreshVehicleList() async {
        guard let client else { return }
        do {
            for v in try await client.vehicles() {
                var existing = (try? await store.vehicle(vin: v.vin)) ?? Vehicle(vin: v.vin, displayName: v.display_name ?? "Tesla")
                existing.displayName = v.display_name ?? existing.displayName
                try await store.upsert(existing)
            }
            vehicles = try await store.vehicles()
            for v in vehicles where loggers[v.vin] == nil {
                loggers[v.vin] = await VehicleLogger(vin: v.vin, source: client, store: store, settings: settings.logger)
            }
            if settings.selectedVIN == nil { settings.selectedVIN = vehicles.first?.vin }
            await pollAll(force: true)
        } catch {
            errorMessage = "Couldn't load vehicles: \(error)"
        }
    }

    // MARK: Sign-in

    func beginSignIn() -> (URL, PKCE)? {
        guard let auth else { errorMessage = "Add your Tesla developer client ID in Settings first."; return nil }
        let pkce = PKCE.generate()
        return (auth.authorizationURL(pkce: pkce), pkce)
    }

    func completeSignIn(callback: URL, pkce: PKCE) async {
        guard let auth else { return }
        do {
            try await auth.completeSignIn(callbackURL: callback, pkce: pkce)
            isSignedIn = true
            await bootstrap()
        } catch {
            errorMessage = "Sign-in failed: \(error)"
        }
    }

    func signOut() async {
        await auth?.signOut()
        isSignedIn = false
        loopTask?.cancel()
        loggers = [:]
        live = [:]
    }

    // MARK: Polling

    func scenePhaseChanged(active: Bool) {
        isForeground = active
        if active {
            Task {
                for l in loggers.values { await l.userBecameActive() }
                await pollAll(force: false)
            }
            ensureLoop()
        } else {
            scheduleBackgroundRefresh()
        }
    }

    /// Runs while the app has execution time: in the foreground, or in the background while
    /// the phone is tracking a drive (location updates keep the app alive).
    private func ensureLoop() {
        guard loopTask == nil || loopTask!.isCancelled else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isForeground || self.phone.isTracking {
                await self.pollAll(force: false)
                let next = self.live.values.compactMap(\.nextPoll).min() ?? Date().addingTimeInterval(30)
                let wait = min(max(next.timeIntervalSinceNow, 1), 30)
                try? await Task.sleep(for: .seconds(wait))
            }
            self?.loopTask = nil
        }
    }

    func pollAll(force: Bool) async {
        for (vin, logger) in loggers {
            let before = live[vin]?.state
            await logger.poll(force: force)
            let s = LiveStatus(snapshot: await logger.latest, state: await logger.state, blocker: await logger.sleepBlocker,
                               lastError: await logger.lastError, nextPoll: await logger.nextDueDate)
            if live[vin] != s {
                live[vin] = s
                dataVersion += 1
            }
            if let before { await notifyTransition(vin: vin, from: before, to: s.state) }
        }
        // Keep paint/wheels/model current for the vehicle render.
        var changed = false
        for var v in vehicles {
            guard let config = live[v.vin]?.snapshot?.config, v.config != config else { continue }
            v.config = config
            try? await store.upsert(v)
            changed = true
        }
        if changed { vehicles = (try? await store.vehicles()) ?? vehicles }

        // Street names for new drives and charges, a few at a time while the app is open.
        if isForeground, Date().timeIntervalSince(lastAddressRun) > 60 {
            lastAddressRun = Date()
            if await addresses.run() { dataVersion += 1 }
        }
    }

    /// Called by the system's background refresh. We get ~30 s; do one round and reschedule.
    func handleBackgroundRefresh() async {
        if loggers.isEmpty { await refreshVehicleList() }
        await pollAll(force: false)
        try? await store.pruneOrphanPhonePositions(olderThan: Date().addingTimeInterval(-86_400))
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        // iOS treats this as a hint; it batches refreshes based on how often you open the app.
        let charging = live.values.contains { $0.state == .charging }
        req.earliestBeginDate = Date().addingTimeInterval(charging ? 10 * 60 : 20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func ingestPhone(_ points: [Position]) async {
        guard settings.usePhoneGPS else { return }
        // Give the track to a car that is driving; otherwise to the selected one. Points that
        // never match a drive are discarded later (see PhoneTrackMatcher / prune).
        var target: VehicleLogger?
        for (vin, l) in loggers where live[vin]?.state == .driving { target = l }
        if target == nil, let vin = selectedVehicle?.vin { target = loggers[vin] }
        await target?.ingestPhoneLocations(points)
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyTransition(vin: String, from: LoggerState, to: LoggerState) async {
        guard from != to else { return }
        let name = vehicles.first { $0.vin == vin }?.displayName ?? "Your car"
        var body: String?
        if from == .charging, to != .charging, settings.notifyChargeComplete,
           let c = try? await store.charges(vin: vin, limit: 1).first, let kwh = c.energyAddedKwh {
            body = "\(name) finished charging: +\(kwh.formatted(.number.precision(.fractionLength(1)))) kWh, now \(c.endBatteryLevel ?? 0)%."
        } else if from == .driving, to != .driving, settings.notifyDriveLogged,
                  let d = try? await store.drives(vin: vin, limit: 1).first {
            body = "Drive logged: \(Fmt(settings.units).distance(d.distanceKm))."
        }
        guard let body else { return }
        let content = UNMutableNotificationContent()
        content.title = "TeslaLink"
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func markDataChanged() { dataVersion += 1 }
}
