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
    public let name = "Apple Look Around"
    /// How far a step along a street goes: about the spacing of Apple's
    /// captures in a city.
    public static let stepMetres = 15.0
    /// The snapshot's size, in points: a terminal panel shows a few dozen
    /// pixels across, and a smaller snapshot is quicker.
    public static let snapshotSize = CGSize(width: 480, height: 270)

    public init() {}

    public func images(near coordinate: GeoCoordinate, within metres: Double) async throws -> [StreetImage] {
        guard try await LookAroundImagery.hasScene(at: coordinate) else { return [] }
        return [LookAroundImagery.image(at: coordinate)]
    }

    public func neighbours(of image: StreetImage, along bearing: Double) async throws -> StreetImageNeighbours {
        async let ahead = scene(from: image, bearing: bearing)
        async let behind = scene(from: image, bearing: bearing + CompassBearing.south)
        return StreetImageNeighbours(previous: try await behind, next: try await ahead)
    }

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

    @MainActor
    private static func hasScene(at coordinate: GeoCoordinate) async throws -> Bool {
        try await scene(at: coordinate) != nil
    }

    @MainActor
    private static func scene(at coordinate: GeoCoordinate) async throws -> MKLookAroundScene? {
        try await MKLookAroundSceneRequest(coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                                              longitude: coordinate.longitude)).scene
    }

    @MainActor
    private static func snapshot(at coordinate: GeoCoordinate) async throws -> ImageBuffer {
        guard let scene = try await scene(at: coordinate) else { throw StreetImageryError.nothingNearby }
        let options = MKLookAroundSnapshotter.Options()
        options.size = snapshotSize
        let snapshot = try await MKLookAroundSnapshotter(scene: scene, options: options).snapshot
        let width = Int(snapshotSize.width), height = Int(snapshotSize.height)
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let image = snapshot.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw MapServiceError.invalidResponse("the Look Around snapshot had no bitmap")
        }
        return try MapKitConversion.pixels(of: image, width: width, height: height)
    }
}
#endif
