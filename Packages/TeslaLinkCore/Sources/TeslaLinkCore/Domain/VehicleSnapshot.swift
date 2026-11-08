import Foundation

/// Connectivity as reported by the non-waking vehicle list/detail endpoint.
public enum OnlineState: String, Codable, Sendable {
    case online, asleep, offline
}

public enum ShiftState: String, Codable, Sendable {
    case park = "P", drive = "D", reverse = "R", neutral = "N"

    /// Car is in a gear that means it is (or is about to be) moving.
    public var isMoving: Bool { self != .park }
}

public enum ChargingState: String, Codable, Sendable {
    case disconnected = "Disconnected"
    case noPower = "NoPower"
    case starting = "Starting"
    case charging = "Charging"
    case complete = "Complete"
    case stopped = "Stopped"

    public var isActive: Bool { self == .starting || self == .charging }
}

/// Where a data point came from. Phone GPS is denser than the vehicle API,
/// so drive tracks are usually a fusion of both.
public enum PositionSource: String, Codable, Sendable {
    case vehicle, phone, inferred
}

/// A normalized, unit-converted (metric) view of one `vehicle_data` response.
/// Everything downstream (state machine, recorders, analytics) works on this,
/// never on raw API JSON, so the data source can be swapped (Fleet API, BLE, mock).
public struct VehicleSnapshot: Codable, Sendable, Equatable {
    public var vin: String
    public var timestamp: Date
    public var onlineState: OnlineState

    // Drive
    public var shiftState: ShiftState?
    public var speedKmh: Double?
    public var powerKw: Double?
    public var odometerKm: Double?
    public var latitude: Double?
    public var longitude: Double?
    public var heading: Double?
    public var elevationM: Double?

    // Battery / charge
    public var batteryLevel: Int?
    public var usableBatteryLevel: Int?
    public var ratedRangeKm: Double?
    public var idealRangeKm: Double?
    public var estimatedRangeKm: Double?
    public var chargingState: ChargingState?
    public var chargeLimitSoc: Int?
    public var chargeEnergyAddedKwh: Double?
    public var chargerPowerKw: Double?
    public var chargerVoltage: Double?
    public var chargerActualCurrent: Double?
    public var chargerPhases: Int?
    public var fastChargerPresent: Bool?
    public var fastChargerType: String?
    public var minutesToFullCharge: Int?
    public var chargePortDoorOpen: Bool?

    // Climate
    public var outsideTempC: Double?
    public var insideTempC: Double?
    public var isClimateOn: Bool?
    public var isPreconditioning: Bool?
    public var climateKeeperMode: String?

    // Body / security
    public var locked: Bool?
    public var sentryMode: Bool?
    public var isUserPresent: Bool?
    public var doorsOpen: DoorState
    public var windowsOpen: Bool?
    public var tirePressureBar: TirePressures?
    public var softwareVersion: String?
    public var softwareUpdateStatus: String?
    public var softwareUpdateDownloadPercent: Int?

    // Config (used for vehicle rendering)
    public var config: VehicleConfig?

    public init(vin: String, timestamp: Date, onlineState: OnlineState = .online) {
        self.vin = vin
        self.timestamp = timestamp
        self.onlineState = onlineState
        self.doorsOpen = DoorState()
    }

    public var hasPosition: Bool { latitude != nil && longitude != nil }
}

public struct DoorState: Codable, Sendable, Equatable {
    public var driverFront = false
    public var passengerFront = false
    public var driverRear = false
    public var passengerRear = false
    public var frontTrunk = false
    public var rearTrunk = false

    public init(driverFront: Bool = false, passengerFront: Bool = false, driverRear: Bool = false,
                passengerRear: Bool = false, frontTrunk: Bool = false, rearTrunk: Bool = false) {
        self.driverFront = driverFront
        self.passengerFront = passengerFront
        self.driverRear = driverRear
        self.passengerRear = passengerRear
        self.frontTrunk = frontTrunk
        self.rearTrunk = rearTrunk
    }

    public var anyDoorOpen: Bool { driverFront || passengerFront || driverRear || passengerRear }
    public var anyTrunkOpen: Bool { frontTrunk || rearTrunk }
}

public struct TirePressures: Codable, Sendable, Equatable {
    public var frontLeft: Double?
    public var frontRight: Double?
    public var rearLeft: Double?
    public var rearRight: Double?

    public init(frontLeft: Double? = nil, frontRight: Double? = nil, rearLeft: Double? = nil, rearRight: Double? = nil) {
        self.frontLeft = frontLeft
        self.frontRight = frontRight
        self.rearLeft = rearLeft
        self.rearRight = rearRight
    }
}

public enum VehicleModel: String, Codable, Sendable, CaseIterable {
    case modelS = "models", model3 = "model3", modelX = "modelx", modelY = "modely", cybertruck = "cybertruck", unknown

    public var displayName: String {
        switch self {
        case .modelS: "Model S"
        case .model3: "Model 3"
        case .modelX: "Model X"
        case .modelY: "Model Y"
        case .cybertruck: "Cybertruck"
        case .unknown: "Tesla"
        }
    }

    /// Code used by Tesla's configurator image compositor.
    public var compositorCode: String {
        switch self {
        case .modelS: "ms"
        case .model3: "m3"
        case .modelX: "mx"
        case .modelY: "my"
        case .cybertruck: "ct"
        case .unknown: "m3"
        }
    }
}

public struct VehicleConfig: Codable, Sendable, Equatable {
    public var model: VehicleModel
    public var trimBadging: String?
    public var exteriorColor: String?
    public var wheelType: String?
    public var optionCodes: [String]

    public init(model: VehicleModel, trimBadging: String? = nil, exteriorColor: String? = nil,
                wheelType: String? = nil, optionCodes: [String] = []) {
        self.model = model
        self.trimBadging = trimBadging
        self.exteriorColor = exteriorColor
        self.wheelType = wheelType
        self.optionCodes = optionCodes
    }
}
