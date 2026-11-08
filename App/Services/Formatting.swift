import Foundation
import SwiftUI
import TeslaLinkCore

/// Unit-aware formatting. Storage is always metric.
struct Fmt {
    let units: UnitSystem
    init(_ units: UnitSystem) { self.units = units }

    var distanceUnit: String { units == .metric ? "km" : "mi" }
    var speedUnit: String { units == .metric ? "km/h" : "mph" }
    var efficiencyUnit: String { units == .metric ? "Wh/km" : "Wh/mi" }

    func km(_ v: Double) -> Double { units == .metric ? v : v / Units.kmPerMile }
    func distance(_ v: Double?, digits: Int = 1) -> String {
        guard let v else { return "–" }
        return "\(km(v).formatted(.number.precision(.fractionLength(digits)))) \(distanceUnit)"
    }
    func speed(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int(km(v).rounded())) \(speedUnit)"
    }
    func efficiency(whPerKm v: Double?) -> String {
        guard let v else { return "–" }
        let x = units == .metric ? v : v * Units.kmPerMile
        return "\(Int(x.rounded())) \(efficiencyUnit)"
    }
    func temperature(_ c: Double?) -> String {
        guard let c else { return "–" }
        return units == .metric ? "\(Int(c.rounded()))°C" : "\(Int((c * 9 / 5 + 32).rounded()))°F"
    }
    func elevation(_ m: Double?) -> String {
        guard let m else { return "–" }
        return units == .metric ? "\(Int(m.rounded())) m" : "\(Int((m * 3.28084).rounded())) ft"
    }
    func energy(_ kwh: Double?) -> String {
        guard let kwh else { return "–" }
        return "\(kwh.formatted(.number.precision(.fractionLength(kwh < 10 ? 2 : 1)))) kWh"
    }
    func power(_ kw: Double?) -> String {
        guard let kw else { return "–" }
        return "\(Int(kw.rounded())) kW"
    }
    func pressure(_ bar: Double?) -> String {
        guard let bar else { return "–" }
        return units == .metric ? bar.formatted(.number.precision(.fractionLength(1))) + " bar" : "\(Int((bar * 14.5038).rounded())) psi"
    }
    func duration(minutes: Double?) -> String {
        guard let m = minutes else { return "–" }
        let h = Int(m) / 60, mm = Int(m.rounded()) % 60
        return h > 0 ? "\(h) h \(mm) min" : "\(mm) min"
    }
    func money(_ v: Double?, currency: String = Locale.current.currency?.identifier ?? "USD") -> String {
        guard let v else { return "–" }
        return v.formatted(.currency(code: currency))
    }
}

extension LoggerState {
    var color: Color {
        switch self {
        case .driving: .blue
        case .charging: .green
        case .updating: .orange
        case .asleep, .suspended: .indigo
        case .offline: .gray
        case .online, .start: .teal
        }
    }

    var symbol: String {
        switch self {
        case .driving: "steeringwheel"
        case .charging: "bolt.fill"
        case .updating: "arrow.down.circle"
        case .asleep: "moon.zzz.fill"
        case .suspended: "moon"
        case .offline: "wifi.slash"
        case .online, .start: "car.fill"
        }
    }
}

extension Color {
    /// Approximate paint colours for the drawn vehicle render.
    static func paint(_ name: String?) -> Color {
        switch name?.lowercased().replacingOccurrences(of: " ", with: "") {
        case "solidblack", "obsidianblack": Color(white: 0.08)
        case "pearlwhite": Color(white: 0.94)
        case "deepblue", "deepbluemetallic": Color(red: 0.10, green: 0.18, blue: 0.40)
        case "midnightsilver", "stealthgrey": Color(red: 0.25, green: 0.27, blue: 0.30)
        case "redmulticoat", "ultrared": Color(red: 0.70, green: 0.05, blue: 0.08)
        case "midnightcherryred": Color(red: 0.35, green: 0.04, blue: 0.08)
        case "quicksilver", "silvermetallic": Color(red: 0.72, green: 0.74, blue: 0.76)
        case "marineblue": Color(red: 0.12, green: 0.30, blue: 0.55)
        default: Color(white: 0.55)
        }
    }
}
