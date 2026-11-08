import Foundation

public enum GeoMath {
    static let earthRadiusM = 6_371_008.8

    /// Great-circle distance (haversine).
    public static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusM * atan2(sqrt(a), sqrt(1 - a))
    }

    public static func pathLengthKm(_ points: [(lat: Double, lon: Double)]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += distanceMeters(lat1: points[i - 1].lat, lon1: points[i - 1].lon, lat2: points[i].lat, lon2: points[i].lon)
        }
        return total / 1000
    }

    /// Ascent/descent with a dead-band so GPS altitude noise doesn't accumulate.
    public static func elevationChange(_ elevations: [Double], threshold: Double = 3) -> (ascent: Double, descent: Double) {
        guard var anchor = elevations.first else { return (0, 0) }
        var up = 0.0, down = 0.0
        for e in elevations.dropFirst() {
            let delta = e - anchor
            if delta >= threshold { up += delta; anchor = e }
            else if delta <= -threshold { down += -delta; anchor = e }
        }
        return (up, down)
    }

    public static func nearestGeofence(_ fences: [Geofence], latitude: Double, longitude: Double) -> Geofence? {
        fences
            .map { ($0, distanceMeters(lat1: $0.latitude, lon1: $0.longitude, lat2: latitude, lon2: longitude)) }
            .filter { $0.1 <= $0.0.radiusM }
            .min { $0.1 < $1.1 }?.0
    }
}
