import Foundation

/// Decides whether the phone's GPS track belongs to the car's drive.
/// The phone moving while the car drives isn't enough: someone else may be driving the car.
public enum PhoneTrackMatcher {
    /// - Returns: true if, for vehicle samples, the phone point closest in time (within
    ///   `maxTimeSkew`) is usually within `maxDistanceM`. With no vehicle positions to compare,
    ///   the phone track is trusted.
    public static func phoneWasInCar(_ positions: [Position], maxTimeSkew: TimeInterval = 90, maxDistanceM: Double = 750) -> Bool {
        let phone = positions.filter { $0.source == .phone }.sorted { $0.timestamp < $1.timestamp }
        let vehicle = positions.filter { $0.source == .vehicle }
        guard !phone.isEmpty, !vehicle.isEmpty else { return true }
        var compared = 0, matched = 0
        for v in vehicle {
            guard let p = phone.min(by: { abs($0.timestamp.timeIntervalSince(v.timestamp)) < abs($1.timestamp.timeIntervalSince(v.timestamp)) }),
                  abs(p.timestamp.timeIntervalSince(v.timestamp)) <= maxTimeSkew else { continue }
            compared += 1
            if GeoMath.distanceMeters(lat1: p.latitude, lon1: p.longitude, lat2: v.latitude, lon2: v.longitude) <= maxDistanceM { matched += 1 }
        }
        return compared == 0 || Double(matched) / Double(compared) >= 0.6
    }
}
