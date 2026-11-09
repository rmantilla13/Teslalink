import Foundation
import TeslaLinkCore

enum UnitSystem: String, Codable, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var label: String { self == .metric ? "Metric (km, °C)" : "Imperial (mi, °F)" }
}

struct AppSettings: Codable, Equatable {
    var region: FleetRegion = .northAmericaAsiaPacific
    var units: UnitSystem = Locale.current.measurementSystem == .us ? .imperial : .metric
    var logger = LoggerSettings()
    /// Phone GPS during drives: far denser tracks, real elevation.
    var usePhoneGPS = true
    var notifyChargeComplete = true
    var notifyDriveLogged = false
    var selectedVIN: String?
    /// Simulated car and generated history, kept in a separate database. Optional so settings
    /// saved by older builds still decode.
    var demoMode: Bool?

    // Overrides for the values compiled in from Config/*.xcconfig.
    var clientIDOverride: String = ""
    var clientSecretOverride: String = ""
    var redirectURIOverride: String = ""

    static let key = "app.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var fleetConfig: FleetAppConfig? {
        let info = Bundle.main.infoDictionary ?? [:]
        func pick(_ override: String, _ key: String) -> String {
            override.isEmpty ? ((info[key] as? String) ?? "") : override
        }
        let id = pick(clientIDOverride, "TeslaClientID")
        let redirect = pick(redirectURIOverride, "TeslaRedirectURI")
        guard !id.isEmpty, !redirect.isEmpty else { return nil }
        let secret = pick(clientSecretOverride, "TeslaClientSecret")
        return FleetAppConfig(clientID: id, clientSecret: secret.isEmpty ? nil : secret, redirectURI: redirect, region: region)
    }
}
