import Foundation

/// Builds a URL for Tesla's public configurator compositor so the app can show the user's
/// actual paint and wheels. Option codes from the API are often stale for Model 3/Y, so the
/// paint and wheel names from `vehicle_config` win when we recognise them.
public enum VehicleImage {
    public enum View: String, Sendable, CaseIterable {
        case threeQuarter = "STUD_3QTR", side = "STUD_SIDE", front = "STUD_FRONT", rear = "STUD_REAR"
    }

    static let paintCodes: [String: String] = [
        "solidblack": "PBSB", "obsidianblack": "PMBL", "pearlwhite": "PPSW", "deepblue": "PPSB",
        "midnightsilver": "PMNG", "redmulticoat": "PPMR", "silvermetallic": "PMSS", "stealthgrey": "PN01",
        "ultrared": "PR01", "quicksilver": "PN00", "midnightcherryred": "PR00", "marineblue": "PB02",
    ]

    static let wheelCodes: [String: String] = [
        "pinwheel18": "W38B", "aero18": "W38B", "stiletto19": "W39B", "sportwheel19": "W39B", "stiletto20": "W32P",
        "photon18": "W18P", "nova19": "W19N", "gemini19": "WY19B", "apollo19": "WY19B", "induction20": "WY20P",
        "uberturbine21": "WY21P", "tempest19": "WT19", "arachnid21": "WT21", "cyberstream": "WX20",
    ]

    public static func paintCode(_ name: String?) -> String? {
        name.flatMap { paintCodes[$0.lowercased().replacingOccurrences(of: " ", with: "")] }
    }

    public static func wheelCode(_ name: String?) -> String? {
        guard let n = name?.lowercased() else { return nil }
        return wheelCodes.first { n.hasPrefix($0.key) }?.value
    }

    public static func url(for config: VehicleConfig, view: View = .threeQuarter, size: Int = 1200) -> URL? {
        guard config.model != .unknown else { return nil }
        var options = config.optionCodes.filter { !$0.hasPrefix("P") && !$0.hasPrefix("W") }
        if let p = paintCode(config.exteriorColor) ?? config.optionCodes.first(where: { $0.count == 4 && $0.hasPrefix("P") }) { options.append(p) }
        if let w = wheelCode(config.wheelType) ?? config.optionCodes.first(where: { $0.hasPrefix("W") }) { options.append(w) }
        var c = URLComponents(string: "https://static-assets.tesla.com/configurator/compositor")!
        c.queryItems = [
            .init(name: "context", value: "design_studio_2"),
            .init(name: "options", value: options.map { "$" + $0 }.joined(separator: ",")),
            .init(name: "view", value: view.rawValue),
            .init(name: "model", value: config.model.compositorCode),
            .init(name: "size", value: String(size)),
            .init(name: "bkba_opt", value: "1"),
        ]
        return c.url
    }
}
