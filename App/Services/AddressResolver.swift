import CoreLocation
import Foundation
import TeslaLinkCore

/// Fills in street addresses for drives and charges with Apple's on-device geocoder.
/// Rate-limited (Apple throttles bursts) and resumable: it simply works through whatever
/// the store reports as missing each time it runs.
actor AddressResolver {
    private let store: LogStore
    private var cache: [String: String] = [:]
    private var running = false

    init(store: LogStore) { self.store = store }

    /// Resolves up to `budget` lookups. Returns true if anything was updated.
    @discardableResult
    func run(budget: Int = 12) async -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        var remaining = budget
        var changed = false

        for var d in (try? await store.drivesMissingAddresses()) ?? [] where remaining > 0 {
            if d.startAddress == nil, let lat = d.startLatitude, let lon = d.startLongitude {
                d.startAddress = await lookup(lat, lon); remaining -= 1
            }
            if d.endAddress == nil, let lat = d.endLatitude, let lon = d.endLongitude, remaining > 0 {
                d.endAddress = await lookup(lat, lon); remaining -= 1
            }
            if d.startAddress != nil || d.endAddress != nil {
                try? await store.save(d)
                changed = true
            }
        }
        for var c in (try? await store.chargesMissingAddresses()) ?? [] where remaining > 0 {
            guard let lat = c.latitude, let lon = c.longitude else { continue }
            c.address = await lookup(lat, lon); remaining -= 1
            if c.address != nil {
                try? await store.save(c)
                changed = true
            }
        }
        return changed
    }

    /// Short, human address: "Main St, Palo Alto" or the place name.
    private func lookup(_ lat: Double, _ lon: Double) async -> String? {
        // ~100 m grid so nearby points share one lookup.
        let key = "\((lat * 1000).rounded() / 1000),\((lon * 1000).rounded() / 1000)"
        if let hit = cache[key] { return hit }
        try? await Task.sleep(for: .milliseconds(1200))
        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)).first else { return nil }
        let street = placemark.thoroughfare ?? placemark.name
        let area = placemark.locality ?? placemark.subAdministrativeArea
        let text = [street, area].compactMap { $0 }.joined(separator: ", ")
        guard !text.isEmpty else { return nil }
        cache[key] = text
        return text
    }
}
