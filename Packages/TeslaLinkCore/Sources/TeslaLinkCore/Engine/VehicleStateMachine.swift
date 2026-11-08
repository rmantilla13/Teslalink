import Foundation

/// Tunables for the logger. Defaults are chosen for the Tesla Fleet API, which bills
/// per request, so they poll less aggressively than a self-hosted server would.
public struct LoggerSettings: Codable, Sendable, Equatable {
    /// Idle time (online, parked, not charging) before we stop requesting vehicle_data
    /// so the car can fall asleep. Requesting vehicle_data keeps it awake.
    public var idleMinutesBeforeSuspend: Double = 15
    /// How long to stay hands-off (status-only polling) once suspended.
    public var suspendMinutes: Double = 21
    /// Only let the car sleep if it is locked.
    public var requireLockedToSleep = false
    /// A drive survives the car going offline this long (tunnels, parking garages).
    public var offlineDriveToleranceMinutes: Double = 15
    /// If two vehicle_data snapshots are further apart than this while not driving,
    /// the gap is reconciled (missed drives, vampire drain).
    public var gapReconcileMinutes: Double = 10
    /// While parked, store a position at most this often.
    public var parkedPositionIntervalMinutes: Double = 5

    public var drivingInterval: TimeInterval = 10
    public var chargingInterval: TimeInterval = 60
    public var onlineInterval: TimeInterval = 60
    public var blockedSleepInterval: TimeInterval = 120
    public var statusInterval: TimeInterval = 60
    public var asleepInterval: TimeInterval = 120
    public var retryInterval: TimeInterval = 30

    public init() {}
}

public enum LoggerState: Codable, Sendable, Equatable {
    case start
    case online
    case driving
    case charging
    case updating(version: String)
    /// Online but intentionally left alone so it can sleep.
    case suspended(since: Date)
    case asleep
    case offline(since: Date)

    public var kind: StateRecord.Kind? {
        switch self {
        case .start: nil
        case .online: .online
        case .driving: .driving
        case .charging: .charging
        case .updating: .updating
        case .suspended: .suspended
        case .asleep: .asleep
        case .offline: .offline
        }
    }

    public var label: String {
        switch self {
        case .start: "Connecting"
        case .online: "Online"
        case .driving: "Driving"
        case .charging: "Charging"
        case .updating: "Updating"
        case .suspended: "Letting car sleep"
        case .asleep: "Asleep"
        case .offline: "Offline"
        }
    }
}

public enum LoggerEvent: Sendable, Equatable {
    /// Full data from `vehicle_data` (this wakes / keeps the car awake).
    case vehicleData(VehicleSnapshot)
    /// Connectivity from the vehicle list/detail endpoint (does not wake the car).
    case status(OnlineState, at: Date)
    /// The user is looking at the app: stop letting the car sleep.
    case userActive(at: Date)
    case fetchFailed(at: Date)
}

public enum PollRequest: String, Sendable, Equatable {
    case vehicleData, statusOnly
}

public struct PollPlan: Sendable, Equatable {
    public var request: PollRequest
    public var after: TimeInterval
    public init(_ request: PollRequest, after: TimeInterval) {
        self.request = request
        self.after = after
    }
}

/// Side effects the state machine asks for. The `VehicleLogger` actor applies them to storage.
public enum LoggerEffect: Sendable, Equatable {
    case stateChanged(StateRecord.Kind, at: Date)
    case startDrive(VehicleSnapshot)
    case recordDrivePosition(VehicleSnapshot)
    case finishDrive(at: Date)
    case startCharge(VehicleSnapshot)
    case recordChargeSample(VehicleSnapshot)
    case finishCharge(at: Date)
    case startUpdate(version: String, at: Date)
    case finishUpdate(at: Date)
    case recordParkedPosition(VehicleSnapshot)
    case reconcileGap(from: VehicleSnapshot, to: VehicleSnapshot)
}

public enum SleepBlocker: String, Sendable, Equatable {
    case userPresent, preconditioning, dogMode, sentryMode, downloadingUpdate, doorsOpen, trunkOpen, unlocked, powerUsage

    public var label: String {
        switch self {
        case .userPresent: "Someone is in the car"
        case .preconditioning: "Preconditioning"
        case .dogMode: "Dog mode"
        case .sentryMode: "Sentry mode"
        case .downloadingUpdate: "Downloading update"
        case .doorsOpen: "A door is open"
        case .trunkOpen: "A trunk is open"
        case .unlocked: "Car is unlocked"
        case .powerUsage: "Drawing power"
        }
    }
}

/// A pure, deterministic state machine modelled on how TeslaMate decides when to poll
/// and when to leave the car alone (re-implemented from scratch for Swift).
///
/// It never does I/O: feed it events, apply the effects it returns, and schedule
/// the next fetch according to `nextPoll`.
public struct VehicleStateMachine: Sendable {
    public private(set) var state: LoggerState = .start
    public private(set) var nextPoll = PollPlan(.statusOnly, after: 0)
    public private(set) var lastSnapshot: VehicleSnapshot?
    public private(set) var lastUsed: Date?
    public private(set) var sleepBlocker: SleepBlocker?
    public var settings: LoggerSettings

    private var lastParkedPosition: Date?
    private var updateVersion: String?

    public init(settings: LoggerSettings = LoggerSettings(), restoring state: LoggerState = .start, lastSnapshot: VehicleSnapshot? = nil) {
        self.settings = settings
        self.state = state
        self.lastSnapshot = lastSnapshot
    }

    public mutating func handle(_ event: LoggerEvent) -> [LoggerEffect] {
        switch event {
        case let .vehicleData(s): return handleData(s)
        case let .status(s, at): return handleStatus(s, at: at)
        case let .userActive(at): return handleUserActive(at)
        case .fetchFailed:
            nextPoll = PollPlan(nextPoll.request, after: settings.retryInterval)
            return []
        }
    }

    // MARK: - Status (non-waking)

    private mutating func handleStatus(_ status: OnlineState, at now: Date) -> [LoggerEffect] {
        var fx: [LoggerEffect] = []
        switch (status, state) {
        case (.online, .suspended(let since)):
            if now.timeIntervalSince(since) >= settings.suspendMinutes * 60 {
                // Still awake after the hands-off window: something keeps it up. Look again.
                // lastUsed is deliberately not reset, so an idle car is re-suspended right away.
                fx += transition(to: .online, at: now)
                nextPoll = PollPlan(.vehicleData, after: 0)
            } else {
                nextPoll = PollPlan(.statusOnly, after: settings.statusInterval)
            }
        case (.online, .start), (.online, .asleep), (.online, .offline):
            // The car woke up (someone is using it, or it's about to charge). Look closer.
            nextPoll = PollPlan(.vehicleData, after: 0)
        case (.online, _):
            nextPoll = PollPlan(.vehicleData, after: 0)

        case (.asleep, .asleep):
            nextPoll = PollPlan(.statusOnly, after: settings.asleepInterval)
        case (.asleep, _):
            fx += closeOpenActivities(at: now)
            fx += transition(to: .asleep, at: now)
            nextPoll = PollPlan(.statusOnly, after: settings.asleepInterval)

        case (.offline, .driving):
            // Tolerate dead zones. Keep the drive open until the tolerance runs out.
            let lastSeen = lastSnapshot?.timestamp ?? now
            if now.timeIntervalSince(lastSeen) > settings.offlineDriveToleranceMinutes * 60 {
                fx += closeOpenActivities(at: lastSeen)
                fx += transition(to: .offline(since: lastSeen), at: lastSeen)
                nextPoll = PollPlan(.statusOnly, after: settings.asleepInterval)
            } else {
                nextPoll = PollPlan(.statusOnly, after: settings.retryInterval)
            }
        case (.offline, .offline):
            nextPoll = PollPlan(.statusOnly, after: settings.asleepInterval)
        case (.offline, _):
            fx += closeOpenActivities(at: now)
            fx += transition(to: .offline(since: now), at: now)
            nextPoll = PollPlan(.statusOnly, after: settings.asleepInterval)
        }
        return fx
    }

    private mutating func handleUserActive(_ now: Date) -> [LoggerEffect] {
        lastUsed = now
        if case .suspended = state {
            state = .online
            nextPoll = PollPlan(.vehicleData, after: 0)
            return [.stateChanged(.online, at: now)]
        }
        return []
    }

    // MARK: - Full data

    private mutating func handleData(_ s: VehicleSnapshot) -> [LoggerEffect] {
        var fx: [LoggerEffect] = []
        let now = s.timestamp
        defer { lastSnapshot = s }

        if let prev = lastSnapshot, state != .driving,
           now.timeIntervalSince(prev.timestamp) >= settings.gapReconcileMinutes * 60 {
            fx.append(.reconcileGap(from: prev, to: s))
        }

        // 1. Software update installing
        if s.softwareUpdateStatus == "installing" {
            let version = s.softwareVersion ?? "unknown"
            if case .updating = state {} else {
                fx += closeOpenActivities(at: now)
                fx.append(.startUpdate(version: version, at: now))
                updateVersion = version
                fx += transition(to: .updating(version: version), at: now)
            }
            nextPoll = PollPlan(.vehicleData, after: settings.onlineInterval)
            return fx
        }
        if case .updating = state {
            fx.append(.finishUpdate(at: now))
            updateVersion = nil
            fx += transition(to: .online, at: now)
        }

        // 2. Driving
        if let gear = s.shiftState, gear.isMoving {
            if state != .driving {
                fx += closeOpenActivities(at: now)
                fx.append(.startDrive(s))
                fx += transition(to: .driving, at: now)
            }
            fx.append(.recordDrivePosition(s))
            lastUsed = now
            nextPoll = PollPlan(.vehicleData, after: settings.drivingInterval)
            return fx
        }
        if state == .driving {
            fx.append(.recordDrivePosition(s))
            fx.append(.finishDrive(at: now))
            fx += transition(to: .online, at: now)
            lastUsed = now
        }

        // 3. Charging
        if s.chargingState?.isActive == true {
            if state != .charging {
                fx += closeOpenActivities(at: now)
                fx.append(.startCharge(s))
                fx += transition(to: .charging, at: now)
            }
            fx.append(.recordChargeSample(s))
            lastUsed = now
            nextPoll = PollPlan(.vehicleData, after: settings.chargingInterval)
            return fx
        }
        if state == .charging {
            fx.append(.recordChargeSample(s))
            fx.append(.finishCharge(at: now))
            fx += transition(to: .online, at: now)
            lastUsed = now
        }

        // 4. Idle online: decide whether to let it sleep.
        switch state {
        case .online: break
        case .suspended:
            // Data arrived while suspended (user forced a refresh). Stay suspended.
            nextPoll = PollPlan(.statusOnly, after: settings.statusInterval)
            return fx
        default:
            fx += transition(to: .online, at: now)
            lastUsed = lastUsed ?? now
        }

        if lastParkedPosition.map({ now.timeIntervalSince($0) >= settings.parkedPositionIntervalMinutes * 60 }) ?? true,
           s.hasPosition {
            fx.append(.recordParkedPosition(s))
            lastParkedPosition = now
        }

        sleepBlocker = Self.sleepBlocker(for: s, settings: settings)
        if sleepBlocker != nil {
            lastUsed = now
            nextPoll = PollPlan(.vehicleData, after: sleepBlocker == .userPresent ? settings.onlineInterval : settings.blockedSleepInterval)
            return fx
        }

        let idle = now.timeIntervalSince(lastUsed ?? now)
        if idle >= settings.idleMinutesBeforeSuspend * 60 {
            fx += transition(to: .suspended(since: now), at: now)
            nextPoll = PollPlan(.statusOnly, after: settings.statusInterval)
        } else {
            nextPoll = PollPlan(.vehicleData, after: settings.onlineInterval)
        }
        return fx
    }

    // MARK: - Helpers

    public static func sleepBlocker(for s: VehicleSnapshot, settings: LoggerSettings) -> SleepBlocker? {
        if s.isUserPresent == true { return .userPresent }
        if s.isPreconditioning == true { return .preconditioning }
        if s.climateKeeperMode == "dog" { return .dogMode }
        if s.sentryMode == true { return .sentryMode }
        if s.softwareUpdateStatus == "downloading", (s.softwareUpdateDownloadPercent ?? 0) < 100 { return .downloadingUpdate }
        if s.doorsOpen.anyDoorOpen { return .doorsOpen }
        if s.doorsOpen.anyTrunkOpen { return .trunkOpen }
        if settings.requireLockedToSleep, s.locked == false { return .unlocked }
        if let p = s.powerKw, p > 0 { return .powerUsage }
        return nil
    }

    private mutating func closeOpenActivities(at date: Date) -> [LoggerEffect] {
        switch state {
        case .driving: return [.finishDrive(at: date)]
        case .charging: return [.finishCharge(at: date)]
        case .updating: return [.finishUpdate(at: date)]
        default: return []
        }
    }

    private mutating func transition(to new: LoggerState, at date: Date) -> [LoggerEffect] {
        let oldKind = state.kind
        state = new
        guard let k = new.kind, k != oldKind else { return [] }
        return [.stateChanged(k, at: date)]
    }
}
