import Foundation

/// The tiles of a downloaded region pack, served from disk.
public struct OfflineTileSource: EncodedTileSource {
    public let pack: RegionPack

    public init(pack: RegionPack) {
        self.pack = pack
    }

    public func info() async throws -> TileSourceInfo {
        TileSourceInfo(name: pack.manifest.name, attribution: pack.manifest.attribution,
                       zoomRange: pack.manifest.zoomRange, bounds: pack.manifest.bounds,
                       featureIdentifiers: pack.manifest.featureIdentifiers ?? .opaque)
    }

    public func tileData(_ id: TileID) async throws -> [UInt8]? {
        guard pack.covers(id) else { return nil }
        let url = pack.tileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Array(try Data(contentsOf: url))
    }
}

/// Search over the names in a pack's tiles: its `place`, `poi` and
/// `transportation_name` layers in the OpenMapTiles schema. The index is
/// built from every tile on disk the first time it is searched.
public actor OfflineSearch: PlaceSearch {
    public let pack: RegionPack
    private var matcher: PlaceMatcher?

    /// The layers whose names are searched.
    static let searchedLayers: Set<String> = ["place", "poi", "transportation_name"]

    /// A name and kind found in two tiles is one place if both lie in one
    /// tile of this zoom (some 10 km across at the equator): a street cut
    /// across tile edges, not two streets of one name in different towns.
    static let deduplicationZoom = 12

    public init(pack: RegionPack) {
        self.pack = pack
    }

    public func search(_ query: String, near region: GeoRect?) async throws -> [Place] {
        let matcher = self.matcher ?? PlaceMatcher(places: OfflineSearch.index(pack))
        self.matcher = matcher
        return matcher.search(query, near: region)
    }

    /// The named features of every stored tile, deepest zoom first so a
    /// place keeps its most precise position. A tile that does not decode
    /// is passed over rather than failing the search.
    static func index(_ pack: RegionPack) -> [Place] {
        var places: [Place] = []
        var seen: Set<PlaceKey> = []
        for tile in pack.storedTiles() {
            guard let bytes = try? Data(contentsOf: pack.tileURL(for: tile)),
                  let decoded = try? VectorTileDecoder.decode(Array(bytes)) else { continue }
            for layer in decoded.layers where searchedLayers.contains(layer.name) {
                for feature in layer.features {
                    guard let place = place(of: feature, in: layer, tile: tile) else { continue }
                    let region = TileID(containing: place.coordinate, zoom: min(tile.zoom, deduplicationZoom))
                    let key = PlaceKey(name: place.name, kind: place.kind, region: region)
                    if seen.insert(key).inserted { places.append(place) }
                }
            }
        }
        return places
    }

    private struct PlaceKey: Hashable {
        var name: String
        var kind: String
        var region: TileID
    }

    private static func place(of feature: VectorFeature, in layer: VectorLayer, tile: TileID) -> Place? {
        guard let name = feature.properties["name"]?.stringValue, !name.isEmpty else { return nil }
        let points = feature.rings.max { $0.count < $1.count } ?? []
        guard !points.isEmpty else { return nil }
        let coordinates = points.map { tile.coordinate(of: $0, extent: layer.extent) }
        let midpoint = feature.kind == .lineString ? WebMercator.midpoint(of: coordinates) : nil
        let coordinate = midpoint ?? coordinates[0]
        let featureClass = feature.properties["class"]?.stringValue
        let kind = layer.name == "poi"
            ? feature.properties["subclass"]?.stringValue ?? featureClass ?? "poi"
            : featureClass ?? layer.name
        return Place(name: name, kind: kind, coordinate: coordinate)
    }
}
