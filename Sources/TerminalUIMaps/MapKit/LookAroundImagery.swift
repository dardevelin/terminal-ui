#if canImport(MapKit)
import CoreGraphics
import Foundation
import MapKit
import TerminalUIIO

/// Apple's Look Around as street imagery: `MKLookAroundSceneRequest` for
/// the scene nearest a coordinate, `MKLookAroundSnapshotter` for its photo.
/// macOS only.
///
/// A scene has no heading a program can set or read, and no sequence:
/// stepping along a street asks for the scene ``stepMetres`` ahead or
/// behind on the bearing the reader walks.
/// Apple's terms cover showing the photo with its credit, not keeping it.
public struct LookAroundImagery: StreetImagery {
    /// The provider's name, as the street view credits it.
    public let name = "Apple Look Around"
    /// How far a step along a street goes: about the spacing of Apple's
    /// captures in a city.
    public static let stepMetres = 15.0
    /// The snapshot's size, in points: a terminal panel shows a few dozen
    /// pixels across, and a smaller snapshot is quicker.
    public static let snapshotSize = CGSize(width: 480, height: 270)

    /// Look Around through Apple's Maps service; it needs no key.
    public init() {}

    /// The scene at `coordinate`, if Apple has one there, as the one image; `metres` is not used, as Apple finds the nearest scene itself.
    public func images(near coordinate: GeoCoordinate, within metres: Double) async throws -> [StreetImage] {
        guard try await LookAroundImagery.hasScene(at: coordinate) else { return [] }
        return [LookAroundImagery.image(at: coordinate)]
    }

    /// The scenes ``stepMetres`` ahead on `bearing` and behind it, each nil where Apple has none.
    public func neighbours(of image: StreetImage, along bearing: Double) async throws -> StreetImageNeighbours {
        async let ahead = scene(from: image, bearing: bearing)
        async let behind = scene(from: image, bearing: bearing + CompassBearing.south)
        return StreetImageNeighbours(previous: try await behind, next: try await ahead)
    }

    /// A snapshot of the scene at the image's coordinate, ``snapshotSize`` in size.
    public func photo(of image: StreetImage) async throws -> ImageBuffer {
        try await LookAroundImagery.snapshot(at: image.coordinate)
    }

    private func scene(from image: StreetImage, bearing: Double) async throws -> StreetImage? {
        let target = image.coordinate.moved(metres: Self.stepMetres, bearing: bearing)
        guard try await LookAroundImagery.hasScene(at: target) else { return nil }
        return LookAroundImagery.image(at: target)
    }

    private static func image(at coordinate: GeoCoordinate) -> StreetImage {
        StreetImage(id: "\(coordinate.latitude),\(coordinate.longitude)", coordinate: coordinate,
                    licence: "Apple Maps terms", attribution: "© Apple Look Around")
    }

    // MapKit's scene and snapshot are taken through their completion
    // handlers, and only what is `Sendable` — whether a scene is there, the
    // pixels — is resumed. Awaiting `MKLookAroundSceneRequest.scene` and
    // `MKLookAroundSnapshotter.snapshot` from the main actor compiles only
    // against an SDK that delivers them there: the macOS 27 SDK marks their
    // completions `NS_SWIFT_UI_ACTOR`, earlier SDKs do not, and with them the
    // await sends the non-`Sendable` request off the main actor.

    @MainActor
    private static func hasScene(at coordinate: GeoCoordinate) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let request = sceneRequest(at: coordinate)
            request.getSceneWithCompletionHandler { scene, error in
                // The request is held until it answers.
                _ = request
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: scene != nil) }
            }
        }
    }

    @MainActor
    private static func snapshot(at coordinate: GeoCoordinate) async throws -> ImageBuffer {
        try await withCheckedThrowingContinuation { continuation in
            let request = sceneRequest(at: coordinate)
            request.getSceneWithCompletionHandler { scene, error in
                _ = request
                guard let scene else {
                    continuation.resume(throwing: error ?? StreetImageryError.nothingNearby)
                    return
                }
                let options = MKLookAroundSnapshotter.Options()
                options.size = snapshotSize
                let snapshotter = MKLookAroundSnapshotter(scene: scene, options: options)
                snapshotter.getSnapshotWithCompletionHandler { snapshot, error in
                    _ = snapshotter
                    guard let snapshot else {
                        continuation.resume(throwing: error
                            ?? MapServiceError.invalidResponse("Apple returned no Look Around snapshot"))
                        return
                    }
                    continuation.resume(with: Result { try pixels(of: snapshot) })
                }
            }
        }
    }

    private static func sceneRequest(at coordinate: GeoCoordinate) -> MKLookAroundSceneRequest {
        MKLookAroundSceneRequest(coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                                    longitude: coordinate.longitude))
    }

    private static func pixels(of snapshot: MKLookAroundSnapshotter.Snapshot) throws -> ImageBuffer {
        let width = Int(snapshotSize.width), height = Int(snapshotSize.height)
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let image = snapshot.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw MapServiceError.invalidResponse("the Look Around snapshot had no bitmap")
        }
        return try MapKitConversion.pixels(of: image, width: width, height: height)
    }
}
#endif
