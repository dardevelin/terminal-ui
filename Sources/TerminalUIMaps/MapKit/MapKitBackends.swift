#if canImport(MapKit)
import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import TerminalUIIO

/// Place search with Apple's `MKLocalSearch`. macOS only.
public struct MapKitSearch: PlaceSearch {
    public init() {}

    public func search(_ query: String, near region: GeoRect?) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await MapKitSearch.run(trimmed, near: region)
    }

    @MainActor
    private static func run(_ query: String, near region: GeoRect?) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = MapKitConversion.region(region) }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap(MapKitConversion.place)
    }
}

/// Directions with Apple's `MKDirections`. macOS only.
public struct MapKitRoutes: RouteProvider {
    public init() {}

    public func route(from origin: GeoCoordinate, to destination: GeoCoordinate,
                      mode: TravelMode) async throws -> Route {
        try await MapKitRoutes.run(from: origin, to: destination, mode: mode)
    }

    @MainActor
    private static func run(from origin: GeoCoordinate, to destination: GeoCoordinate,
                            mode: TravelMode) async throws -> Route {
        let request = MKDirections.Request()
        request.source = MapKitConversion.mapItem(origin)
        request.destination = MapKitConversion.mapItem(destination)
        request.transportType = switch mode {
        case .driving: .automobile
        case .walking: .walking
        case .cycling: .cycling
        }
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw MapServiceError.noRoute("MapKit found no route")
        }
        let polylines = route.steps.map { MapKitConversion.coordinates(of: $0.polyline) }
        let maneuvers = StepShapes.maneuvers(of: polylines)
        let steps = route.steps.indices.compactMap { index -> RouteStep? in
            let step = route.steps[index]
            guard let start = polylines[index].first else { return nil }
            let instruction = step.instructions.isEmpty ? "Continue" : step.instructions
            return RouteStep(instruction: instruction, distance: step.distance, duration: 0, coordinate: start,
                             maneuver: maneuvers[index])
        }
        return Route(coordinates: MapKitConversion.coordinates(of: route.polyline), distance: route.distance,
                     duration: route.expectedTravelTime, steps: steps)
    }
}

/// The basemap as pictures from Apple's `MKMapSnapshotter`, one snapshot
/// per tile, drawn by the renderer as half-blocks. macOS only.
public struct MapKitSnapshotSource: MapTileSource {
    /// The pixels across a tile's snapshot. A tile is 256 dots, and a
    /// half-block is a 2-dot-wide, 4-dot-tall cell's two halves, so a few
    /// pixels a cell is all a terminal can show.
    public static let defaultPixelsPerTile = 256

    /// MapKit's zooms: its map data runs to street level, about OSM's 20.
    public static let zoomRange = 0...20

    public static let attribution = "Apple Maps"

    private let pixelsPerTile: Int

    public init(pixelsPerTile: Int = MapKitSnapshotSource.defaultPixelsPerTile) {
        self.pixelsPerTile = max(1, pixelsPerTile)
    }

    public func info() async throws -> TileSourceInfo {
        TileSourceInfo(name: "Apple Maps", attribution: MapKitSnapshotSource.attribution,
                       zoomRange: MapKitSnapshotSource.zoomRange)
    }

    public func tile(_ id: TileID) async throws -> MapTile? {
        guard id.isValid, MapKitSnapshotSource.zoomRange.contains(id.zoom) else { return nil }
        return .raster(try await MapKitSnapshotSource.snapshot(id, pixels: pixelsPerTile))
    }

    /// An `MKMapRect` is the Web Mercator square in map points, so a tile's
    /// rect is its share of `MKMapRect.world` and the snapshot lines up
    /// with every other source's tile exactly.
    @MainActor
    private static func snapshot(_ id: TileID, pixels: Int) async throws -> ImageBuffer {
        let world = MKMapRect.world
        let (minimum, maximum) = id.worldBounds
        let options = MKMapSnapshotter.Options()
        options.mapRect = MKMapRect(x: world.origin.x + minimum.x * world.size.width,
                                    y: world.origin.y + minimum.y * world.size.height,
                                    width: (maximum.x - minimum.x) * world.size.width,
                                    height: (maximum.y - minimum.y) * world.size.height)
        options.size = CGSize(width: pixels, height: pixels)
        let snapshot = try await MKMapSnapshotter(options: options).start()
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let image = snapshot.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw MapServiceError.invalidResponse("the snapshot had no bitmap")
        }
        return try MapKitConversion.pixels(of: image, width: pixels, height: pixels)
    }
}

/// Between MapKit's types and this library's.
enum MapKitConversion {
    static func region(_ rect: GeoRect) -> MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: rect.center.latitude,
                                                          longitude: rect.center.longitude),
                           span: MKCoordinateSpan(latitudeDelta: rect.north - rect.south,
                                                  longitudeDelta: rect.east - rect.west))
    }

    @MainActor
    static func mapItem(_ coordinate: GeoCoordinate) -> MKMapItem {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(macOS 26, *) {
            return MKMapItem(location: location, address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }

    @MainActor
    static func place(_ item: MKMapItem) -> Place? {
        guard let name = item.name else { return nil }
        let coordinate: CLLocationCoordinate2D
        let address: String?
        if #available(macOS 26, *) {
            coordinate = item.location.coordinate
            address = item.address?.fullAddress
        } else {
            coordinate = item.placemark.coordinate
            address = item.placemark.title
        }
        let kind = item.pointOfInterestCategory.map(categoryName) ?? "place"
        return Place(name: name, kind: kind,
                     coordinate: GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
                     address: address, identifier: item.identifier.map { .mapKit($0.rawValue) })
    }

    /// `MKPointOfInterestCategory` raw values read `MKPOICategoryCafe`; the
    /// kind is the part after the prefix, lowercased.
    private static func categoryName(_ category: MKPointOfInterestCategory) -> String {
        let prefix = "MKPOICategory"
        let raw = category.rawValue
        return (raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw).lowercased()
    }

    static func coordinates(of polyline: MKPolyline) -> [GeoCoordinate] {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                                   count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// The image drawn into an RGBA bitmap of 8 bits a channel, alpha last
    /// and premultiplied, as `ImageBuffer` holds it.
    static func pixels(of image: CGImage, width: Int, height: Int) throws -> ImageBuffer {
        let bytesPerPixel = 4
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: UInt8.bitWidth, bytesPerRow: width * bytesPerPixel,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw MapServiceError.invalidResponse("could not draw the snapshot") }
        return try ImageBuffer(rgba: rgba, width: width, height: height)
    }
}
#endif
