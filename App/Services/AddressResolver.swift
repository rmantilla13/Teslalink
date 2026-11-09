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

    /// Resolves up to `budget` geocoder lookups; answers already in the cache are free.
    /// Returns true if anything was updated.
    @discardableResult
    func run(budget: Int = 12) async -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        var remaining = budget
        var changed = false

        for var d in (try? await store.drivesMissingAddresses()) ?? [] {
            var filled = false
            if d.startAddress == nil, let lat = d.startLatitude, let lon = d.startLongitude,
               let text = await address(lat, lon, budget: &remaining) {
                d.startAddress = text
                filled = true
            }
            if d.endAddress == nil, let lat = d.endLatitude, let lon = d.endLongitude,
               let text = await address(lat, lon, budget: &remaining) {
                d.endAddress = text
                filled = true
            }
            if filled {
                try? await store.save(d)
                changed = true
            }
        }
        for var c in (try? await store.chargesMissingAddresses()) ?? [] {
            guard let lat = c.latitude, let lon = c.longitude,
                  let text = await address(lat, lon, budget: &remaining) else { continue }
            c.address = text
            try? await store.save(c)
            changed = true
        }
        return changed
    }

    /// A cached answer costs nothing; only geocoder calls (which Apple throttles) spend the
    /// budget. Counting cache hits let trips between the same two places use it all up, so
    /// other places and charges waited minutes, and the demo, rebuilt at every launch, showed
    /// "Unknown" each time.
    private func address(_ lat: Double, _ lon: Double, budget remaining: inout Int) async -> String? {
        if let hit = cache[Self.key(lat, lon)] { return hit }
        guard remaining > 0 else { return nil }
        remaining -= 1
        return await lookup(lat, lon)
    }

    /// ~100 m grid so nearby points share one lookup.
    private static func key(_ lat: Double, _ lon: Double) -> String {
        "\((lat * 1000).rounded() / 1000),\((lon * 1000).rounded() / 1000)"
    }

    /// Short, human address: "Main St, Palo Alto" or the place name.
    private func lookup(_ lat: Double, _ lon: Double) async -> String? {
        try? await Task.sleep(for: .milliseconds(1200))
        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)).first else { return nil }
        let street = placemark.thoroughfare ?? placemark.name
        let area = placemark.locality ?? placemark.subAdministrativeArea
        let text = [street, area].compactMap { $0 }.joined(separator: ", ")
        guard !text.isEmpty else { return nil }
        cache[Self.key(lat, lon)] = text
        return text
    }
}
