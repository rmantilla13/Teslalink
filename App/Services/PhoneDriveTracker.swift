import CoreLocation
import Foundation
import TeslaLinkCore

/// Uses the phone's GPS as a high-resolution sensor during drives.
///
/// - Significant-location-change monitoring relaunches the app (even after it was terminated)
///   when you start moving, which is how a drive gets noticed without opening the app.
/// - While moving, live location updates keep the app running in the background, so the
///   logger keeps polling the car for the whole drive.
/// - After ~5 minutes stationary, tracking stops and iOS can suspend the app again.
@MainActor
final class PhoneDriveTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var updatesTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    private var buffer: [Position] = []
    private var lastStored: CLLocation?
    private var lastMovement = Date()

    private(set) var isTracking = false
    var onPositions: (([Position]) -> Void)?
    var onMovementStarted: (() -> Void)?

    private let stopAfterStationary: TimeInterval = 5 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    func stop() {
        manager.stopMonitoringSignificantLocationChanges()
        stopTracking()
    }

    // MARK: Tracking

    private func beginTracking() {
        guard !isTracking else { return }
        isTracking = true
        lastMovement = Date()
        backgroundSession = CLBackgroundActivitySession()
        onMovementStarted?()
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    guard let self, !Task.isCancelled else { break }
                    if let loc = update.location { self.handle(loc) }
                    if Date().timeIntervalSince(self.lastMovement) > self.stopAfterStationary {
                        self.stopTracking()
                        break
                    }
                }
            } catch {
                self?.stopTracking()
            }
        }
    }

    private func stopTracking() {
        flush()
        updatesTask?.cancel()
        updatesTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        isTracking = false
    }

    private func handle(_ loc: CLLocation) {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { return }
        if loc.speed > 1.5 { lastMovement = loc.timestamp }
        // Keep a point every 5 s or 25 m, whichever comes first: smooth maps, small database.
        if let last = lastStored, loc.timestamp.timeIntervalSince(last.timestamp) < 5, loc.distance(from: last) < 25 { return }
        lastStored = loc
        buffer.append(Position(vin: "", timestamp: loc.timestamp, latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                               elevationM: loc.verticalAccuracy > 0 && loc.verticalAccuracy < 30 ? loc.altitude : nil,
                               speedKmh: loc.speed >= 0 ? loc.speed * 3.6 : nil, source: .phone))
        if buffer.count >= 12 { flush() }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        onPositions?(buffer)
        buffer.removeAll()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // A significant-change event means we moved ~500 m. Track in detail; tracking stops
        // by itself after 5 stationary minutes, and the logger only keeps points that line up
        // with a drive the car itself reports.
        Task { @MainActor in self.beginTracking() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.manager.authorizationStatus == .authorizedWhenInUse { self.manager.requestAlwaysAuthorization() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
