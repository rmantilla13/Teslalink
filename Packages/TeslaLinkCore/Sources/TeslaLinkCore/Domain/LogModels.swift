import Foundation

public typealias RecordID = Int64

public struct Vehicle: Codable, Sendable, Identifiable, Equatable {
    public var id: String { vin }
    public var vin: String
    public var displayName: String
    public var config: VehicleConfig?
    /// Derived kWh per rated km (see `EfficiencyEstimator`). nil until enough charges are logged.
    public var efficiencyKwhPerKm: Double?

    public init(vin: String, displayName: String, config: VehicleConfig? = nil, efficiencyKwhPerKm: Double? = nil) {
        self.vin = vin
        self.displayName = displayName
        self.config = config
        self.efficiencyKwhPerKm = efficiencyKwhPerKm
    }
}

public struct Position: Codable, Sendable, Equatable {
    public var id: RecordID?
    public var vin: String
    public var driveID: RecordID?
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var elevationM: Double?
    public var speedKmh: Double?
    public var powerKw: Double?
    public var odometerKm: Double?
    public var batteryLevel: Int?
    public var ratedRangeKm: Double?
    public var outsideTempC: Double?
    public var insideTempC: Double?
    public var source: PositionSource

    public init(id: RecordID? = nil, vin: String, driveID: RecordID? = nil, timestamp: Date,
                latitude: Double, longitude: Double, elevationM: Double? = nil, speedKmh: Double? = nil,
                powerKw: Double? = nil, odometerKm: Double? = nil, batteryLevel: Int? = nil,
                ratedRangeKm: Double? = nil, outsideTempC: Double? = nil, insideTempC: Double? = nil,
                source: PositionSource = .vehicle) {
        self.id = id
        self.vin = vin
        self.driveID = driveID
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.elevationM = elevationM
        self.speedKmh = speedKmh
        self.powerKw = powerKw
        self.odometerKm = odometerKm
        self.batteryLevel = batteryLevel
        self.ratedRangeKm = ratedRangeKm
        self.outsideTempC = outsideTempC
        self.insideTempC = insideTempC
        self.source = source
    }

    public init?(snapshot s: VehicleSnapshot, driveID: RecordID?) {
        guard let lat = s.latitude, let lon = s.longitude else { return nil }
        self.init(vin: s.vin, driveID: driveID, timestamp: s.timestamp, latitude: lat, longitude: lon,
                  elevationM: s.elevationM, speedKmh: s.speedKmh, powerKw: s.powerKw, odometerKm: s.odometerKm,
                  batteryLevel: s.batteryLevel, ratedRangeKm: s.ratedRangeKm, outsideTempC: s.outsideTempC,
                  insideTempC: s.insideTempC, source: .vehicle)
    }
}

public struct ChargeSample: Codable, Sendable, Equatable {
    public var id: RecordID?
    public var sessionID: RecordID
    public var timestamp: Date
    public var batteryLevel: Int?
    public var usableBatteryLevel: Int?
    public var ratedRangeKm: Double?
    public var idealRangeKm: Double?
    public var chargeEnergyAddedKwh: Double?
    public var chargerPowerKw: Double?
    public var chargerVoltage: Double?
    public var chargerActualCurrent: Double?
    public var chargerPhases: Int?
    public var outsideTempC: Double?
    public var fastChargerType: String?

    public init(id: RecordID? = nil, sessionID: RecordID, timestamp: Date, batteryLevel: Int? = nil,
                usableBatteryLevel: Int? = nil, ratedRangeKm: Double? = nil, idealRangeKm: Double? = nil,
                chargeEnergyAddedKwh: Double? = nil, chargerPowerKw: Double? = nil, chargerVoltage: Double? = nil,
                chargerActualCurrent: Double? = nil, chargerPhases: Int? = nil, outsideTempC: Double? = nil,
                fastChargerType: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.batteryLevel = batteryLevel
        self.usableBatteryLevel = usableBatteryLevel
        self.ratedRangeKm = ratedRangeKm
        self.idealRangeKm = idealRangeKm
        self.chargeEnergyAddedKwh = chargeEnergyAddedKwh
        self.chargerPowerKw = chargerPowerKw
        self.chargerVoltage = chargerVoltage
        self.chargerActualCurrent = chargerActualCurrent
        self.chargerPhases = chargerPhases
        self.outsideTempC = outsideTempC
        self.fastChargerType = fastChargerType
    }

    public init(snapshot s: VehicleSnapshot, sessionID: RecordID) {
        self.init(sessionID: sessionID, timestamp: s.timestamp, batteryLevel: s.batteryLevel,
                  usableBatteryLevel: s.usableBatteryLevel, ratedRangeKm: s.ratedRangeKm, idealRangeKm: s.idealRangeKm,
                  chargeEnergyAddedKwh: s.chargeEnergyAddedKwh, chargerPowerKw: s.chargerPowerKw,
                  chargerVoltage: s.chargerVoltage, chargerActualCurrent: s.chargerActualCurrent,
                  chargerPhases: s.chargerPhases, outsideTempC: s.outsideTempC,
                  fastChargerType: s.fastChargerPresent == true ? (s.fastChargerType ?? "DC") : nil)
    }
}

public struct Drive: Codable, Sendable, Identifiable, Hashable {
    public var id: RecordID?
    public var vin: String
    public var startDate: Date
    public var endDate: Date?
    public var startLatitude: Double?
    public var startLongitude: Double?
    public var endLatitude: Double?
    public var endLongitude: Double?
    public var startAddress: String?
    public var endAddress: String?
    public var startGeofenceID: RecordID?
    public var endGeofenceID: RecordID?
    public var distanceKm: Double?
    public var durationMin: Double?
    public var startOdometerKm: Double?
    public var endOdometerKm: Double?
    public var startBatteryLevel: Int?
    public var endBatteryLevel: Int?
    public var startRatedRangeKm: Double?
    public var endRatedRangeKm: Double?
    public var speedMaxKmh: Double?
    public var powerMaxKw: Double?
    public var powerMinKw: Double?
    public var ascentM: Double?
    public var descentM: Double?
    public var outsideTempAvgC: Double?
    public var insideTempAvgC: Double?
    public var energyUsedKwh: Double?
    /// True when reconstructed from sparse snapshots (app wasn't running during the drive).
    public var isInferred: Bool
    /// A simplified route (lat, lon pairs, at most ~32) for list thumbnails.
    public var routePreview: [RoutePoint]?

    public init(id: RecordID? = nil, vin: String, startDate: Date, isInferred: Bool = false) {
        self.id = id
        self.vin = vin
        self.startDate = startDate
        self.isInferred = isInferred
    }

    public var isOpen: Bool { endDate == nil }

    public var efficiencyWhPerKm: Double? {
        guard let e = energyUsedKwh, let d = distanceKm, d > 0.5 else { return nil }
        return e * 1000 / d
    }

    public var averageSpeedKmh: Double? {
        guard let d = distanceKm, let m = durationMin, m > 0 else { return nil }
        return d / (m / 60)
    }
}

public struct RoutePoint: Codable, Sendable, Hashable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

public struct ChargeSession: Codable, Sendable, Identifiable, Hashable {
    public var id: RecordID?
    public var vin: String
    public var startDate: Date
    public var endDate: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var address: String?
    public var geofenceID: RecordID?
    public var startBatteryLevel: Int?
    public var endBatteryLevel: Int?
    public var startRatedRangeKm: Double?
    public var endRatedRangeKm: Double?
    public var startIdealRangeKm: Double?
    public var endIdealRangeKm: Double?
    public var energyAddedKwh: Double?
    /// Energy drawn from the wall (includes losses). Only reliable with dense sampling.
    public var energyUsedKwh: Double?
    public var powerMaxKw: Double?
    public var durationMin: Double?
    public var outsideTempAvgC: Double?
    public var fastChargerType: String?
    public var cost: Double?
    public var sampleCount: Int

    public init(id: RecordID? = nil, vin: String, startDate: Date) {
        self.id = id
        self.vin = vin
        self.startDate = startDate
        self.sampleCount = 0
    }

    public var isOpen: Bool { endDate == nil }
    public var isDCFast: Bool { fastChargerType != nil }

    public var chargingEfficiency: Double? {
        guard let added = energyAddedKwh, let used = energyUsedKwh, used > 0 else { return nil }
        let e = added / used
        return e > 0 && e <= 1.05 ? min(e, 1) : nil
    }
}

/// A stretch of time in one high-level state, like TeslaMate's `states` table.
public struct StateRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case online, asleep, offline, driving, charging, updating, suspended }
    public var id: RecordID?
    public var vin: String
    public var kind: Kind
    public var startDate: Date
    public var endDate: Date?

    public init(id: RecordID? = nil, vin: String, kind: Kind, startDate: Date, endDate: Date? = nil) {
        self.id = id
        self.vin = vin
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct SoftwareUpdate: Codable, Sendable, Equatable {
    public var id: RecordID?
    public var vin: String
    public var version: String
    public var startDate: Date
    public var endDate: Date?

    public init(id: RecordID? = nil, vin: String, version: String, startDate: Date, endDate: Date? = nil) {
        self.id = id
        self.vin = vin
        self.version = version
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct Geofence: Codable, Sendable, Identifiable, Hashable {
    public var id: RecordID?
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radiusM: Double
    public var tariff: Tariff?

    public init(id: RecordID? = nil, name: String, latitude: Double, longitude: Double, radiusM: Double = 50, tariff: Tariff? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusM = radiusM
        self.tariff = tariff
    }

    public func contains(latitude lat: Double, longitude lon: Double) -> Bool {
        GeoMath.distanceMeters(lat1: latitude, lon1: longitude, lat2: lat, lon2: lon) <= radiusM
    }
}
