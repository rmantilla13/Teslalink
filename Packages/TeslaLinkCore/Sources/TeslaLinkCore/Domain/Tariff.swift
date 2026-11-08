import Foundation

/// Electricity pricing for a geofence (home, work, a favourite Supercharger...).
public struct Tariff: Codable, Sendable, Hashable {
    public enum Basis: String, Codable, Sendable {
        /// Billed on energy drawn from the wall (home meter). Falls back to energy added.
        case energyUsed
        /// Billed on energy delivered to the battery (most DC networks).
        case energyAdded
        /// Billed by the minute.
        case perMinute
    }

    public struct Window: Codable, Sendable, Hashable {
        /// Minutes after local midnight, [start, end). end < start wraps past midnight.
        public var startMinute: Int
        public var endMinute: Int
        public var pricePerUnit: Double

        public init(startMinute: Int, endMinute: Int, pricePerUnit: Double) {
            self.startMinute = startMinute
            self.endMinute = endMinute
            self.pricePerUnit = pricePerUnit
        }

        func contains(minuteOfDay m: Int) -> Bool {
            startMinute <= endMinute ? (m >= startMinute && m < endMinute) : (m >= startMinute || m < endMinute)
        }
    }

    public var basis: Basis
    public var pricePerUnit: Double
    public var sessionFee: Double
    /// Optional time-of-use windows that override `pricePerUnit`.
    public var windows: [Window]
    public var currencyCode: String

    public init(basis: Basis = .energyUsed, pricePerUnit: Double, sessionFee: Double = 0,
                windows: [Window] = [], currencyCode: String = "USD") {
        self.basis = basis
        self.pricePerUnit = pricePerUnit
        self.sessionFee = sessionFee
        self.windows = windows
        self.currencyCode = currencyCode
    }

    public func price(at date: Date, calendar: Calendar = .current) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return windows.first { $0.contains(minuteOfDay: m) }?.pricePerUnit ?? pricePerUnit
    }
}
