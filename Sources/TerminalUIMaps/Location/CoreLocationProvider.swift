#if canImport(CoreLocation)
import CoreLocation
import Foundation

/// Fixes from Apple's Location Services. macOS only.
///
/// Location Services asks the user once per app, and names the app by its
/// bundle: a process with no `Info.plist` has no bundle identifier and no
/// usage description, and its requests are refused without a prompt. A
/// SwiftPM executable gets both by embedding a plist in its binary — the
/// linker's `-sectcreate __TEXT __info_plist` — which `locationd` then
/// reads as the bundle's (checked on macOS 27: the request reaches
/// `locationd` as `org.terminalui.maps` and it posts the prompt). The Maps
/// example builds so when `TERMINALUI_MAPS_LOCATION_PLIST=1` is set; see
/// `design/maps.md`.
///
/// `CLLocationManager` delivers to the run loop of the thread that made
/// it. The runtime's main thread runs no run loop, so the manager lives on
/// a thread of its own that does.
public struct CoreLocationProvider: LocationProvider {
    public init() {}

    public var name: String { "Location Services" }

    /// The key Location Services requires the app's `Info.plist` to state
    /// why it asks.
    public static let usageDescriptionKeys = ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"]

    /// Whether this process has a usage description, without which no
    /// prompt is shown.
    public static var hasUsageDescription: Bool {
        usageDescriptionKeys.contains { Bundle.main.object(forInfoDictionaryKey: $0) != nil }
    }

    /// How long the thread runs its run loop between looks at whether the
    /// stream was cancelled.
    static let runLoopSlice: TimeInterval = 0.25

    public func fixes() -> AsyncThrowingStream<LocationFix, any Error> {
        AsyncThrowingStream { continuation in
            guard CoreLocationProvider.hasUsageDescription else {
                continuation.finish(throwing: LocationError.unavailable(
                    "this binary has no Info.plist, so Location Services will not ask: "
                        + "build it with TERMINALUI_MAPS_LOCATION_PLIST=1"))
                return
            }
            let cancelled = LineSocket.CancellationFlag()
            continuation.onTermination = { _ in cancelled.cancel() }
            let thread = Thread {
                let receiver = LocationReceiver(continuation: continuation)
                let manager = CLLocationManager()
                manager.delegate = receiver
                receiver.authorizationChanged(manager)
                manager.requestWhenInUseAuthorization()
                while !cancelled.isCancelled, !receiver.isFinished {
                    RunLoop.current.run(until: Date().addingTimeInterval(CoreLocationProvider.runLoopSlice))
                }
                manager.stopUpdatingLocation()
                manager.delegate = nil
            }
            thread.name = "TerminalUIMaps.CoreLocation"
            thread.start()
        }
    }
}

/// The manager's delegate, on the provider's thread only.
private final class LocationReceiver: NSObject, CLLocationManagerDelegate {
    private let continuation: AsyncThrowingStream<LocationFix, any Error>.Continuation
    private(set) var isFinished = false
    private var isUpdating = false

    init(continuation: AsyncThrowingStream<LocationFix, any Error>.Continuation) {
        self.continuation = continuation
    }

    func authorizationChanged(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if !isUpdating {
                isUpdating = true
                manager.startUpdatingLocation()
            }
        case .denied:
            finish(LocationError.notAuthorized(
                "Location Services refused: allow Maps in System Settings › Privacy & Security › Location Services"))
        case .restricted:
            finish(LocationError.notAuthorized("Location Services are restricted on this Mac"))
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    private func finish(_ error: any Error) {
        guard !isFinished else { return }
        isFinished = true
        continuation.finish(throwing: error)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy >= 0 {
            continuation.yield(LocationFix(
                coordinate: GeoCoordinate(latitude: location.coordinate.latitude,
                                          longitude: location.coordinate.longitude),
                horizontalAccuracy: location.horizontalAccuracy,
                course: location.course >= 0 ? location.course : nil,
                speed: location.speed >= 0 ? location.speed : nil,
                timestamp: location.timestamp, source: .coreLocation))
        }
    }

    /// `kCLErrorLocationUnknown` is a moment without a fix, and the manager
    /// keeps trying; a denial arrives as `kCLErrorDenied`, which also comes
    /// while the prompt is still up, so only the authorization status is
    /// taken as the answer.
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        authorizationChanged(manager)
    }
}
#endif
