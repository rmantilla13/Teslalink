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
    /// In demo mode, or with at least one linked Tesla account (even one that needs
    /// reconnecting: its cars and history stay on screen).
    private(set) var isSignedIn = false
    var errorMessage: String?
    /// A `teslalink://setup` link waiting for the user's yes (RootView shows the review).
    var pendingSetupLink: SetupLinkRequest?

    private(set) var store: LogStore
    /// Linked Tesla accounts, in the order they were added.
    private(set) var accounts: [TeslaAccount] = []
    private(set) var accountStatus: [String: AccountStatus] = [:]
    /// One auth and client per account, made once and kept: Tesla refresh tokens are
    /// single-use, and only a single `FleetAuth` per token can coalesce refreshes safely.
    private var links: [String: AccountLink] = [:]
    private var loggers: [String: VehicleLogger] = [:]
    /// The account each car's logger polls through, to replace the logger if that changes.
    private var loggerOwner: [String: String] = [:]
    private var pendingSignIn: PendingSignIn?
    /// The developer app's client secret from setup, with its client ID (in the Keychain).
    private var developerSecret: DeveloperSecret?
    private var loopTask: Task<Void, Never>?
    private var wakeRequested = false
    private(set) var isForeground = false
    let phone = PhoneDriveTracker()
    private var addresses: AddressResolver
    private var lastAddressRun = Date.distantPast

    init() {
        var loaded = AppSettings.load()
        if DebugLaunch.demo {
            _ = AppSettings.storedDemoMode   // capture the saved flag before anything is saved
            loaded.demoMode = true
        }
        developerSecret = Self.migrateClientSecret(&loaded)
        KeychainValue(service: "com.teslalink.developer-app", account: "client-secret").save(nil)   // an unpaired early format
        let db = Self.openStore(demo: loaded.demoMode == true)
        settings = loaded
        store = db
        addresses = AddressResolver(store: db)
        accounts = AccountStore.load()
        if accounts.isEmpty, let first = Self.migrateLegacySignIn(region: loaded.region) { accounts = [first] }
        #if DEBUG
        if accounts.isEmpty, DebugLaunch.fakeAccount {
            accounts = [TeslaAccount(id: "debug-fake", region: loaded.region, email: "driver@example.com")]
        }
        #endif
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

    var isDemo: Bool { settings.demoMode == true }

    /// Real and demo data live in separate files so they never mix.
    ///
    /// The demo starts from a fresh file each time. Its simulated charge is logged like a real
    /// one, so a kept file gained another finished session on every launch, and the seeded
    /// history (30 days ending "now") went stale.
    private static func openStore(demo: Bool) -> LogStore {
        let url = URL.applicationSupportDirectory.appending(path: "TeslaLink", directoryHint: .isDirectory)
        let files = FileManager.default
        try? files.createDirectory(at: url, withIntermediateDirectories: true)
        let dbURL: URL
        if demo {
            // Earlier demo files go, with their -wal and -shm. The new one gets a name of its own:
            // an earlier demo store can still be open (an address lookup in flight), and SQLite
            // deletes a store's -wal and -shm by name when it closes.
            for name in (try? files.contentsOfDirectory(atPath: url.path)) ?? [] where name.hasPrefix("demo") {
                try? files.removeItem(at: url.appending(path: name))
            }
            dbURL = url.appending(path: "demo-\(UUID().uuidString).sqlite")
        } else {
            dbURL = url.appending(path: "log.sqlite")
        }
        do {
            return try LogStore(path: dbURL.path)
        } catch {
            fatalError("Could not open database: \(error)")
        }
    }

    // MARK: Demo

    func enterDemo() { settings.demoMode = true }
    func leaveDemo() { settings.demoMode = nil }

    private func startDemo() async {
        do {
            try await DemoData.seed(store)
        } catch {
            errorMessage = "Couldn't create demo data: \(error)"
            return
        }
        vehicles = (try? await store.vehicles()) ?? []
        var fast = settings.logger
        fast.chargingInterval = 5
        fast.onlineInterval = 10
        fast.drivingInterval = 5
        let car = await DemoCar(store: store)
        loggers[DemoData.vin] = await VehicleLogger(vin: DemoData.vin, source: car, store: store, settings: fast)
        settings.selectedVIN = DemoData.vin
        await pollAll(force: true)
        wakeLoop()
    }

    var selectedVehicle: Vehicle? {
        vehicles.first { $0.vin == settings.selectedVIN } ?? vehicles.first
    }

    func status(for vin: String) -> LiveStatus { live[vin] ?? LiveStatus() }

    // MARK: Setup

    private func configureAPI() {
        links = [:]
        if isDemo { isSignedIn = true; return }
        for account in accounts { links[account.id] = makeLink(account) }
        isSignedIn = !accounts.isEmpty
    }

    private func makeLink(_ account: TeslaAccount) -> AccountLink? {
        guard let config = fleetConfig(region: account.region) else { return nil }
        let auth = FleetAuth(config: config, store: KeychainTokenStore(account: account.tokenKey))
        return AccountLink(auth: auth, client: FleetAPIClient(region: account.region, tokens: auth))
    }

    /// The developer app's details: from setup (secret in the Keychain), else compiled in from
    /// Config/*.xcconfig. nil until there's a client ID and a redirect URI.
    func fleetConfig(region: FleetRegion) -> FleetAppConfig? {
        let app = developerApp
        guard !app.clientID.isEmpty, !app.redirectURI.isEmpty else { return nil }
        return FleetAppConfig(clientID: app.clientID, clientSecret: app.clientSecret.isEmpty ? nil : app.clientSecret,
                              redirectURI: app.redirectURI, region: region)
    }

    var hasDeveloperApp: Bool { fleetConfig(region: settings.region) != nil }

    /// The developer app in use, and whether it came from the build rather than setup.
    var developerApp: (clientID: String, clientSecret: String, redirectURI: String, fromBuild: Bool) {
        let builtID = Self.built("TeslaClientID")
        let id = settings.clientIDOverride.isEmpty ? builtID : settings.clientIDOverride
        // A secret only goes with the client ID it was saved for.
        var secret = developerSecret?.clientID == id ? developerSecret?.secret ?? "" : ""
        if secret.isEmpty, id == builtID { secret = Self.built("TeslaClientSecret") }
        let redirect = settings.redirectURIOverride.isEmpty ? Self.built("TeslaRedirectURI") : settings.redirectURIOverride
        return (id, secret, redirect, settings.clientIDOverride.isEmpty && !id.isEmpty)
    }

    /// A value compiled in from Config/*.xcconfig (via Info.plist).
    private static func built(_ key: String) -> String {
        (Bundle.main.infoDictionary?[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Saves the developer app from setup or a setup link. Linked accounts keep their sign-ins
    /// (a different client ID makes them reconnect once Tesla refuses the old tokens).
    func saveDeveloperApp(clientID: String, clientSecret: String?, redirectURI: String, region: FleetRegion? = nil) {
        let paired = clientSecret.map { DeveloperSecret(clientID: clientID, secret: $0) }
        DeveloperSecret.save(paired)
        developerSecret = paired?.secret.isEmpty == false ? paired : nil
        var updated = settings
        updated.clientIDOverride = clientID
        updated.redirectURIOverride = redirectURI
        if let region { updated.region = region }
        settings = updated
        guard !isDemo else { return }
        loggers = [:]
        loggerOwner = [:]
        live = [:]
        configureAPI()
        Task { await bootstrap() }
    }

    /// A secret typed into an older build sat in the settings file; it belongs in the Keychain.
    /// The settings copy goes only once the Keychain has it.
    private static func migrateClientSecret(_ settings: inout AppSettings) -> DeveloperSecret? {
        let legacy = settings.clientSecretOverride
        guard !legacy.isEmpty else { return DeveloperSecret.load() }
        let id = settings.clientIDOverride.isEmpty ? built("TeslaClientID") : settings.clientIDOverride
        let paired = DeveloperSecret(clientID: id, secret: legacy)
        DeveloperSecret.save(paired)
        guard DeveloperSecret.load() == paired else { return paired }
        settings.clientSecretOverride = ""
        settings.save()
        return paired
    }

    /// The single sign-in from before accounts becomes the first account. The old Keychain
    /// item is deleted only once the new one reads back, so a failure just retries next launch.
    private static func migrateLegacySignIn(region: FleetRegion) -> TeslaAccount? {
        let legacy = KeychainTokenStore(account: "default")
        guard let token = legacy.load() else { return nil }
        let claims = TokenClaims(jwt: token.accessToken)
        // The token was issued for the region the app was set to, whatever its claims say.
        let account = TeslaAccount(id: claims?.subject ?? UUID().uuidString, subject: claims?.subject, region: region,
                                   email: claims?.email, name: claims?.name)
        let moved = KeychainTokenStore(account: account.tokenKey)
        moved.save(token)
        guard moved.load() == token else { return nil }
        AccountStore.save([account])
        legacy.save(nil)
        return account
    }

    private func applySettings(_ old: AppSettings) {
        if old.demoMode != settings.demoMode {
            loopTask?.cancel()
            loopTask = nil
            loggers = [:]
            live = [:]
            store = Self.openStore(demo: isDemo)
            addresses = AddressResolver(store: store)
            if !isDemo { settings.selectedVIN = nil }
            configureAPI()
            dataVersion += 1
            Task { await bootstrap() }
            return
        }
        // The region only picks where new accounts sign in, and the developer app changes through
        // saveDeveloperApp: neither touches a linked account here.
        if old.logger != settings.logger {
            for l in loggers.values { Task { await l.updateSettings(settings.logger) } }
        }
        if old.usePhoneGPS != settings.usePhoneGPS {
            if settings.usePhoneGPS, isSignedIn, !isDemo, !vehicles.isEmpty { phone.start() } else { phone.stop() }
        }
    }

    private func bootstrap() async {
        if isDemo {
            vehicles = (try? await store.vehicles()) ?? []
            await startDemo()
            return
        }
        guard isSignedIn else { vehicles = []; return }
        await routeCars()   // the cars last seen, before Tesla answers
        await refreshVehicleList()
        ensureLoop()
    }

    /// Asks every linked account for its cars. One account failing (expired sign-in, region
    /// not registered) doesn't stop the others.
    func refreshVehicleList() async {
        guard !isDemo else { return }
        for account in accounts {
            guard let link = links[account.id] else {
                accountStatus[account.id] = .problem("Set up your Tesla developer app to connect.")
                continue
            }
            do {
                let cars = try await link.client.vehicles()
                for car in cars {
                    var known = (try? await store.vehicle(vin: car.vin)) ?? Vehicle(vin: car.vin, displayName: car.display_name ?? "Tesla")
                    known.displayName = car.display_name ?? known.displayName
                    try await store.upsert(known)
                }
                updateAccount(account.id) { $0.vins = cars.map(\.vin) }
                accountStatus[account.id] = .connected
            } catch {
                accountStatus[account.id] = Self.status(for: error, region: account.region)
            }
        }
        await routeCars()
        if !vehicles.contains(where: { $0.vin == settings.selectedVIN }) { settings.selectedVIN = vehicles.first?.vin }
        // Ask for location once there's a car to log: never on the welcome screen, in demo mode,
        // or for an account that hasn't listed a car.
        if settings.usePhoneGPS, !vehicles.isEmpty { phone.start() }
        await pollAll(force: true)
        wakeLoop()
    }

    /// Shows linked accounts' cars and gives each a logger that polls through the account that
    /// owns it. A car shared between accounts is polled once (see `AccountRouting`).
    private func routeCars() async {
        let stored = (try? await store.vehicles()) ?? []
        let linked = Set(accounts.flatMap(\.vins))
        vehicles = linked.isEmpty ? stored : stored.filter { linked.contains($0.vin) }
        let owner = AccountRouting.owners(accounts.map { (id: $0.id, vins: $0.vins) })
        for vin in Array(loggers.keys) where owner[vin] == nil || owner[vin] != loggerOwner[vin] {
            loggers[vin] = nil
            loggerOwner[vin] = nil
            live[vin] = nil
        }
        for (vin, account) in owner where loggers[vin] == nil {
            guard let link = links[account] else { continue }
            loggers[vin] = await VehicleLogger(vin: vin, source: link.client, store: store, settings: settings.logger)
            loggerOwner[vin] = account
        }
    }

    private func updateAccount(_ id: String, _ change: (inout TeslaAccount) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        var account = accounts[i]
        change(&account)
        guard account != accounts[i] else { return }
        accounts[i] = account
        AccountStore.save(accounts)
    }

    /// The cars an account brings, by name.
    func cars(of account: TeslaAccount) -> [Vehicle] {
        vehicles.filter { account.vins.contains($0.vin) }
    }

    private static func status(for error: Error, region: FleetRegion) -> AccountStatus {
        switch error {
        case AuthError.notSignedIn, FleetAPIError.unauthorized:
            return .needsReconnect
        case FleetAPIError.http(let code, _) where code == 412:
            return .problem("Your developer app isn't registered in \(region.displayName) yet. Run scripts/register-partner.sh with REGION=\(region.rawValue).")
        case FleetAPIError.http(let code, _) where code == 421:
            return .problem("Tesla says this account belongs to another region. Reconnect it to sign in there.")
        case FleetAPIError.http(let code, _):
            return .problem("Tesla answered \(code). Try again later.")
        case FleetAPIError.rateLimited:
            return .problem("Tesla is limiting requests. TeslaLink will try again shortly.")
        case let error as URLError:
            return .problem(error.localizedDescription)
        default:
            return .problem("Couldn't load cars: \(error)")
        }
    }

    // MARK: Accounts

    /// Opens Tesla's sign-in for a new account, or to renew `reconnecting`. Returns the page to
    /// show, or nil (with a message) when there's no developer app yet.
    func beginSignIn(region: FleetRegion, reconnecting: String? = nil, isRegionRetry: Bool = false) -> URL? {
        guard let config = fleetConfig(region: region) else {
            errorMessage = "Set up your Tesla developer app first."
            return nil
        }
        let auth = FleetAuth(config: config, store: InMemoryTokenStore())
        let pkce = PKCE.generate()
        pendingSignIn = PendingSignIn(auth: auth, pkce: pkce, region: region, redirectURI: config.redirectURI,
                                      reconnecting: reconnecting, isRegionRetry: isRegionRetry)
        return auth.authorizationURL(pkce: pkce)
    }

    /// Where Tesla's sign-in returns to, for the web authentication session.
    var signInRedirectURI: String? { pendingSignIn?.redirectURI }

    func cancelSignIn() { pendingSignIn = nil }

    /// Finishes the sign-in Tesla just returned from: links the account (or renews it) and
    /// loads its cars.
    func completeSignIn(callback: URL) async -> SignInOutcome {
        guard let pending = pendingSignIn else { return .failed("That sign-in expired. Try again.") }
        pendingSignIn = nil
        let result: SignInResult
        do {
            result = try await pending.auth.completeSignIn(callbackURL: callback, pkce: pending.pkce)
        } catch {
            return .failed(Self.describe(signInError: error))
        }
        // Tesla's token says where the account lives. The token only works in the region it
        // was requested for, so a mismatch means signing in again there (once, never a loop).
        if let home = result.claims?.region, home != pending.region, !pending.isRegionRetry {
            return .wrongRegion(home)
        }
        // Which account this is. The token's subject decides when there is one: Reconnect on
        // one account never takes another person's sign-in.
        let subject = result.claims?.subject
        let target = pending.reconnecting.flatMap { r in accounts.first { $0.id == r } }
        if let target, let known = target.subject, let subject, known != subject {
            return .failed("That's a different Tesla account than \(target.title ?? "this one"). Sign in with its own details to reconnect it, or use Add Tesla account to link the other one.")
        }
        var id = subject.flatMap { s in accounts.first { $0.subject == s || $0.id == s }?.id } ?? target?.id
        var cars: [String]?
        if id == nil, subject == nil {
            // No subject to tell accounts apart: the same cars as a linked account means the same person.
            if let list = try? await FleetAPIClient(region: pending.region, tokens: pending.auth).vehicles() {
                cars = list.map(\.vin)
                id = AccountRouting.match(vins: list.map(\.vin), in: accounts.map { (id: $0.id, vins: $0.vins) })
            }
        }
        var account = accounts.first { $0.id == (id ?? subject) } ?? TeslaAccount(id: id ?? subject ?? UUID().uuidString, region: pending.region)
        let tokens = KeychainTokenStore(account: account.tokenKey)
        tokens.save(result.token)
        guard tokens.load() == result.token else { return .failed("Couldn't save the sign-in to the Keychain. Try again.") }
        account.region = pending.region
        account.subject = subject ?? account.subject
        account.email = result.claims?.email ?? account.email
        account.name = result.claims?.name ?? account.name
        if let cars { account.vins = cars }
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        AccountStore.save(accounts)
        // A fresh auth on the account's own Keychain token; its cars' loggers pick it up.
        links[account.id] = makeLink(account)
        for (vin, owner) in loggerOwner where owner == account.id {
            loggers[vin] = nil
            loggerOwner[vin] = nil
        }
        accountStatus[account.id] = .connected
        let wasSignedIn = isSignedIn
        isSignedIn = true
        if wasSignedIn { await refreshVehicleList() } else { await bootstrap() }
        return .linked
    }

    /// Unlinks an account: its sign-in is removed and its cars stop updating. Their history stays.
    func disconnect(_ id: String) async {
        await links[id]?.auth.signOut()
        KeychainTokenStore(account: "account.\(id)").save(nil)
        links[id] = nil
        accounts.removeAll { $0.id == id }
        accountStatus[id] = nil
        AccountStore.save(accounts)
        if accounts.isEmpty {
            isSignedIn = false
            phone.stop()
            loopTask?.cancel()
            loggers = [:]
            loggerOwner = [:]
            live = [:]
            vehicles = []
            settings.selectedVIN = nil
        } else {
            await routeCars()
            if !vehicles.contains(where: { $0.vin == settings.selectedVIN }) { settings.selectedVIN = vehicles.first?.vin }
        }
    }

    private static func describe(signInError error: Error) -> String {
        switch error {
        case AuthError.stateMismatch:
            return "The sign-in was interrupted. Try again."
        case AuthError.missingCode:
            return "Tesla didn't send a sign-in code back. Check that the redirect URI in your developer app is teslalink://auth/callback."
        case AuthError.tokenEndpoint(let status, let body):
            let code = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
            switch code {
            case "invalid_client", "unauthorized_client":
                return "Tesla didn't accept the developer app (\(code ?? "")). Check its client ID and secret in setup."
            case "invalid_grant":
                return "Tesla rejected the sign-in code. Try again, and check the redirect URI matches your developer app."
            default:
                return "Tesla refused the sign-in (\(status)). Try again."
            }
        case let error as URLError:
            return error.localizedDescription
        default:
            return "Sign-in failed: \(error)"
        }
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
                // Until every car has reported once, check back every couple of seconds. Each
                // logger still decides whether a request is due, so this costs no extra calls.
                let waiting = self.loggers.isEmpty || self.loggers.keys.contains { self.live[$0]?.snapshot == nil }
                let next = self.live.values.compactMap(\.nextPoll).min() ?? Date().addingTimeInterval(30)
                let wait = waiting ? 2 : min(max(next.timeIntervalSinceNow, 1), 30)
                let until = Date().addingTimeInterval(wait)
                while Date() < until, !self.wakeRequested, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                }
                self.wakeRequested = false
            }
            self?.loopTask = nil
        }
    }

    /// Runs the poll loop now instead of letting it finish its sleep (new cars, a forced read).
    private func wakeLoop() {
        wakeRequested = true
        ensureLoop()
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

        // Street names for new drives and charges, a few at a time while the app is open. A
        // run can take a while (each lookup is spaced out), so it doesn't hold up polling.
        if isForeground, Date().timeIntervalSince(lastAddressRun) > 60 {
            lastAddressRun = Date()
            let resolver = addresses
            Task { if await resolver.run() { dataVersion += 1 } }
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
        guard settings.usePhoneGPS, !isDemo else { return }
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
