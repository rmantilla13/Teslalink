import Foundation

/// Raw Tesla Fleet API payloads. Only fields the logger uses are decoded; everything is optional
/// because Tesla omits fields freely depending on firmware, model and car state.
public enum FleetAPI {
    public struct Envelope<T: Decodable>: Decodable {
        public var response: T?
        public var error: String?
    }

    public struct VehicleSummary: Decodable, Sendable, Equatable {
        public var id: Int64?
        public var vehicle_id: Int64?
        public var vin: String
        public var display_name: String?
        public var state: String?
        public var option_codes: String?
    }

    public struct VehicleData: Decodable, Sendable {
        public var vin: String
        public var display_name: String?
        public var state: String?
        public var option_codes: String?
        public var charge_state: ChargeState?
        public var climate_state: ClimateState?
        public var drive_state: DriveState?
        public var vehicle_state: VState?
        public var vehicle_config: VConfig?
    }

    public struct ChargeState: Decodable, Sendable {
        public var battery_level: Int?
        public var usable_battery_level: Int?
        public var battery_range: Double?
        public var ideal_battery_range: Double?
        public var est_battery_range: Double?
        public var charging_state: String?
        public var charge_limit_soc: Int?
        public var charge_energy_added: Double?
        public var charger_power: Double?
        public var charger_voltage: Double?
        public var charger_actual_current: Double?
        public var charger_phases: Int?
        public var fast_charger_present: Bool?
        public var fast_charger_type: String?
        public var minutes_to_full_charge: Int?
        public var charge_port_door_open: Bool?
        public var timestamp: Int64?
    }

    public struct ClimateState: Decodable, Sendable {
        public var inside_temp: Double?
        public var outside_temp: Double?
        public var is_climate_on: Bool?
        public var is_preconditioning: Bool?
        public var climate_keeper_mode: String?
    }

    public struct DriveState: Decodable, Sendable {
        public var shift_state: String?
        public var speed: Double?
        public var power: Double?
        public var latitude: Double?
        public var longitude: Double?
        public var heading: Double?
        public var timestamp: Int64?
    }

    public struct SoftwareUpdate: Decodable, Sendable {
        public var status: String?
        public var download_perc: Int?
        public var version: String?
    }

    public struct VState: Decodable, Sendable {
        public var odometer: Double?
        public var locked: Bool?
        public var sentry_mode: Bool?
        public var is_user_present: Bool?
        public var df: Int?, dr: Int?, pf: Int?, pr: Int?, ft: Int?, rt: Int?
        public var fd_window: Int?, fp_window: Int?, rd_window: Int?, rp_window: Int?
        public var tpms_pressure_fl: Double?, tpms_pressure_fr: Double?, tpms_pressure_rl: Double?, tpms_pressure_rr: Double?
        public var car_version: String?
        public var software_update: SoftwareUpdate?
        public var timestamp: Int64?
    }

    public struct VConfig: Decodable, Sendable {
        public var car_type: String?
        public var trim_badging: String?
        public var exterior_color: String?
        public var wheel_type: String?
    }

    public struct TokenResponse: Decodable, Sendable {
        public var access_token: String
        public var refresh_token: String?
        public var id_token: String?
        public var expires_in: Double
        public var token_type: String?
    }
}

public enum Units {
    public static let kmPerMile = 1.609344
}

extension VehicleSnapshot {
    /// Normalizes a Fleet API payload (imperial units) to a metric snapshot.
    public init(_ v: FleetAPI.VehicleData, receivedAt: Date) {
        let mi = Units.kmPerMile
        let stamp = [v.drive_state?.timestamp, v.charge_state?.timestamp, v.vehicle_state?.timestamp]
            .compactMap { $0 }.max().map { Date(timeIntervalSince1970: Double($0) / 1000) }
        self.init(vin: v.vin, timestamp: stamp ?? receivedAt, onlineState: OnlineState(rawValue: v.state ?? "") ?? .online)

        if let d = v.drive_state {
            shiftState = d.shift_state.flatMap(ShiftState.init(rawValue:))
            speedKmh = d.speed.map { $0 * mi } ?? (shiftState == nil || shiftState == .park ? 0 : nil)
            powerKw = d.power
            latitude = d.latitude
            longitude = d.longitude
            heading = d.heading
        }
        if let c = v.charge_state {
            batteryLevel = c.battery_level
            usableBatteryLevel = c.usable_battery_level
            ratedRangeKm = c.battery_range.map { $0 * mi }
            idealRangeKm = c.ideal_battery_range.map { $0 * mi }
            estimatedRangeKm = c.est_battery_range.map { $0 * mi }
            chargingState = c.charging_state.flatMap(ChargingState.init(rawValue:))
            chargeLimitSoc = c.charge_limit_soc
            chargeEnergyAddedKwh = c.charge_energy_added
            chargerPowerKw = c.charger_power
            chargerVoltage = c.charger_voltage
            chargerActualCurrent = c.charger_actual_current
            chargerPhases = c.charger_phases
            fastChargerPresent = c.fast_charger_present
            fastChargerType = c.fast_charger_type
            minutesToFullCharge = c.minutes_to_full_charge
            chargePortDoorOpen = c.charge_port_door_open
        }
        if let c = v.climate_state {
            insideTempC = c.inside_temp
            outsideTempC = c.outside_temp
            isClimateOn = c.is_climate_on
            isPreconditioning = c.is_preconditioning
            climateKeeperMode = c.climate_keeper_mode
        }
        if let s = v.vehicle_state {
            odometerKm = s.odometer.map { $0 * mi }
            locked = s.locked
            sentryMode = s.sentry_mode
            isUserPresent = s.is_user_present
            func open(_ x: Int?) -> Bool { (x ?? 0) > 0 }
            doorsOpen = DoorState(driverFront: open(s.df), passengerFront: open(s.pf), driverRear: open(s.dr),
                                  passengerRear: open(s.pr), frontTrunk: open(s.ft), rearTrunk: open(s.rt))
            let windows = [s.fd_window, s.fp_window, s.rd_window, s.rp_window].compactMap { $0 }
            windowsOpen = windows.isEmpty ? nil : windows.contains { $0 > 0 }
            tirePressureBar = TirePressures(frontLeft: s.tpms_pressure_fl, frontRight: s.tpms_pressure_fr,
                                            rearLeft: s.tpms_pressure_rl, rearRight: s.tpms_pressure_rr)
            softwareVersion = s.car_version
            softwareUpdateStatus = s.software_update?.status.flatMap { $0.isEmpty ? nil : $0 }
            softwareUpdateDownloadPercent = s.software_update?.download_perc
        }
        let model = VehicleModel(rawValue: (v.vehicle_config?.car_type ?? "").lowercased()) ?? VehicleModel(vin: v.vin)
        config = VehicleConfig(model: model, trimBadging: v.vehicle_config?.trim_badging,
                               exteriorColor: v.vehicle_config?.exterior_color, wheelType: v.vehicle_config?.wheel_type,
                               optionCodes: (v.option_codes ?? "").split(separator: ",").map(String.init))
    }
}

extension VehicleModel {
    /// The 4th VIN character encodes the model line.
    public init(vin: String) {
        let chars = Array(vin.uppercased())
        guard chars.count >= 4 else { self = .unknown; return }
        switch chars[3] {
        case "S": self = .modelS
        case "3": self = .model3
        case "X": self = .modelX
        case "Y": self = .modelY
        case "C": self = .cybertruck
        default: self = .unknown
        }
    }
}
