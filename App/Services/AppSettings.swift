import Foundation
import TeslaLinkCore

enum UnitSystem: String, Codable, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var label: String { self == .metric ? "Metric (km, °C)" : "Imperial (mi, °F)" }
}

struct AppSettings: Codable, Equatable {
    /// Where new Tesla accounts sign in (each linked account keeps its own). Starts from the
    /// phone's country.
    var region: FleetRegion = AppSettings.phoneRegion
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

    // The developer app from setup, overriding the values compiled in from Config/*.xcconfig.
    var clientIDOverride: String = ""
    /// Only read to move a secret saved by an older build into the Keychain (see AppModel).
    var clientSecretOverride: String = ""
    var redirectURIOverride: String = ""

    static let key = "app.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    /// The demo flag as saved before this launch. A `-TLDemo` launch shows the demo for that run only.
    static let storedDemoMode: Bool? = load().demoMode

    func save() {
        var stored = self
        if DebugLaunch.demo { stored.demoMode = Self.storedDemoMode }
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// The Tesla region a phone set to this country most likely uses.
    static var phoneRegion: FleetRegion {
        let region = Locale.current.region
        return .suggested(country: region?.identifier, continent: region?.continent?.identifier,
                          subregion: region?.containingRegion?.identifier)
    }
}
