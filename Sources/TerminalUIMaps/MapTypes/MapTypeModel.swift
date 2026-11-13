import Observation
import TerminalUI

/// The kinds of map a reader picks between, as Apple Maps offers them.
public enum MapType: String, Sendable, CaseIterable, Identifiable, Codable {
    /// The vector map: areas, roads and names.
    case explore
    /// Imagery alone.
    case satellite
    /// Imagery with the roads and names over it.
    case hybrid
    /// The map over shaded relief and contour lines.
    case terrain

    /// The type's raw value, which identifies it.
    public var id: String { rawValue }

    /// The type's name as a picker shows it: "Satellite".
    public var title: String {
        switch self {
        case .explore: "Explore"
        case .satellite: "Satellite"
        case .hybrid: "Hybrid"
        case .terrain: "Terrain"
        }
    }
}

/// A source of imagery a backend offers.
public struct ImageryOption: Sendable, Identifiable {
    /// Tells options apart, so choosing one again keeps its store.
    public var id: String
    /// What the reader is shown: "Apple", "Sentinel-2 + USGS".
    public var name: String
    /// What it is, in a line: its coverage and detail.
    public var detail: String
    /// Where the imagery's tiles come from.
    public var source: any MapTileSource
    /// The same imagery with its provider's roads and names drawn in,
    /// which a hybrid map shows in place of drawing the basemap's over it —
    /// the only hybrid a picture basemap can have.
    public var hybridSource: (any MapTileSource)?

    /// An imagery option drawn from `source`, with its own hybrid source if the provider has one.
    public init(id: String, name: String, detail: String, source: any MapTileSource,
                hybridSource: (any MapTileSource)? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.source = source
        self.hybridSource = hybridSource
    }
}

/// A source of heights a backend offers.
public struct TerrainOption: Sendable {
    /// Tells options apart, so choosing one again keeps its store.
    public var id: String
    /// What the reader is shown: "AWS Terrain Tiles".
    public var name: String
    /// What it is, in a line: what the terrain map draws from it.
    public var detail: String
    /// Where the elevation tiles come from.
    public var source: any MapTileSource

    /// A terrain option drawn from `source`.
    public init(id: String, name: String, detail: String, source: any MapTileSource) {
        self.id = id
        self.name = name
        self.detail = detail
        self.source = source
    }
}

/// What a backend can draw each map type with.
public struct MapTypeOffer: Sendable {
    /// The imagery it offers, the default first; none where it has none.
    public var imagery: [ImageryOption]
    /// The heights it offers; nil where it has none, so the terrain type is unavailable.
    public var terrain: TerrainOption?
    /// Whether the basemap is vector, so its roads and names can be drawn
    /// over imagery; a picture basemap (MapKit's) cannot.
    public var basemapIsVector: Bool

    /// An offer of this imagery and terrain over a vector or a picture basemap.
    public init(imagery: [ImageryOption], terrain: TerrainOption?, basemapIsVector: Bool) {
        self.imagery = imagery
        self.terrain = terrain
        self.basemapIsVector = basemapIsVector
    }

    /// The open sources, which need no key and cover the world: USGS's
    /// imagery leading in the United States with Sentinel-2 2016 filling
    /// in, and AWS Terrain Tiles.
    public static func open(basemapIsVector: Bool = true, transport: any HTTPTransport = URLSessionTransport(),
                            userAgent: String) -> MapTypeOffer {
        MapTypeOffer(imagery: [ImageryOption.open(transport: transport, userAgent: userAgent)],
                     terrain: TerrainOption.open(transport: transport, userAgent: userAgent),
                     basemapIsVector: basemapIsVector)
    }
}

extension MapTypeOffer {
    /// The sample town's own imagery and ground, which need no network:
    /// every map type of ``SampleTileSource``'s map.
    public static let sample = MapTypeOffer(
        imagery: [ImageryOption(id: "sample", name: "\(SampleTown.name) from the air",
                                detail: "sample imagery of the town; no network", source: SampleImagerySource())],
        terrain: TerrainOption(id: "sample", name: "\(SampleTown.name)'s ground",
                               detail: "sample heights: shaded relief, contours", source: SampleTerrainSource()),
        basemapIsVector: true)
}

extension ImageryOption {
    /// USGS's orthoimagery in the United States, Sentinel-2 cloudless 2016
    /// elsewhere.
    public static func open(transport: any HTTPTransport = URLSessionTransport(),
                            userAgent: String) -> ImageryOption {
        ImageryOption(id: "open", name: "Sentinel-2 + USGS",
                      detail: "Sentinel-2 2016 worldwide (10 m), USGS in the US (1 m)",
                      source: TileSourceChain([RasterTileSource.usgsImagery(transport: transport, userAgent: userAgent),
                                               RasterTileSource.sentinel2Cloudless2016(transport: transport,
                                                                                       userAgent: userAgent)],
                                              name: "Sentinel-2 + USGS"))
    }
}

extension TerrainOption {
    /// AWS Terrain Tiles.
    public static func open(transport: any HTTPTransport = URLSessionTransport(),
                            userAgent: String) -> TerrainOption {
        TerrainOption(id: "aws", name: "AWS Terrain Tiles", detail: "AWS Terrain Tiles: shaded relief, contours",
                      source: RasterTileSource.awsTerrain(transport: transport, userAgent: userAgent))
    }
}

/// One row of a map-type picker: the type, whether this backend can draw
/// it, and in a line what it draws from — or why not, so the picker says
/// so rather than the map coming up blank.
public struct MapTypeOption: Sendable, Equatable, Identifiable {
    /// The map type the row offers.
    public var type: MapType
    /// Whether this backend can draw the type.
    public var isAvailable: Bool
    /// What the type draws from, or why it is unavailable, in a line.
    public var detail: String

    /// The map type's id, which identifies the row.
    public var id: String { type.id }

    /// A picker row for `type`.
    public init(type: MapType, isAvailable: Bool, detail: String) {
        self.type = type
        self.isAvailable = isAvailable
        self.detail = detail
    }
}

/// The map type a map shows and the layers it takes for it — the model
/// behind a map-type picker, testable without a screen.
///
/// Give it what the backend offers; pick a type; hand ``layers`` to the
/// map. It keeps a store for the imagery and one for the terrain, made the
/// first time a type needs them and given a new source when the backend
/// or the imagery chosen changes.
///
/// ```swift
/// let types = MapTypeModel(offer: .open())
/// types.select(.hybrid)
/// MapView(camera: $camera, store: basemap).mapLayers(types.layers)
/// ```
@MainActor
@Observable
public final class MapTypeModel {
    /// The map type shown.
    public private(set) var mapType: MapType = .explore
    /// What the current backend can draw each map type with.
    public private(set) var offer: MapTypeOffer
    /// Which of the offer's imagery is used.
    public private(set) var imageryIndex = 0
    /// The store of imagery tiles; nil until a satellite or hybrid map is first shown.
    public private(set) var imageryStore: MapTileStore?
    /// The store of elevation tiles; nil until a terrain map, or realistic
    /// elevation, is first shown.
    public private(set) var terrainStore: MapTileStore?
    /// Whether the map stands up — SwiftUI MapKit's elevation, part of a
    /// map's style: realistic, every type raises its buildings and stands
    /// on the offer's terrain where it has one.
    public var elevation = MapElevation.flat {
        didSet { prepareStores() }
    }

    /// Which source each store was given, by the option's id and whether
    /// it is the hybrid one, so choosing it again keeps its tiles.
    @ObservationIgnored private var imageryKey: String?
    @ObservationIgnored private var terrainKey: String?

    /// A model of what `offer` can draw, showing Explore. It makes no store
    /// until a type needs one.
    public init(offer: MapTypeOffer) {
        self.offer = offer
    }

    /// The imagery in use, if the backend has any.
    public var imagery: ImageryOption? {
        offer.imagery.indices.contains(imageryIndex) ? offer.imagery[imageryIndex] : offer.imagery.first
    }

    /// Every type, available or not, and why.
    public var options: [MapTypeOption] { MapType.allCases.map(option(for:)) }

    /// The picker row for `type`: whether this backend can draw it, and from what or why not.
    public func option(for type: MapType) -> MapTypeOption {
        switch type {
        case .explore:
            return MapTypeOption(type: type, isAvailable: true, detail: "the map: areas, roads and names")
        case .satellite:
            guard let imagery else {
                return MapTypeOption(type: type, isAvailable: false, detail: "this backend has no imagery")
            }
            return MapTypeOption(type: type, isAvailable: true, detail: imagery.detail)
        case .hybrid:
            guard let imagery else {
                return MapTypeOption(type: type, isAvailable: false, detail: "this backend has no imagery")
            }
            if imagery.hybridSource != nil {
                return MapTypeOption(type: type, isAvailable: true, detail: "\(imagery.name) with its own roads and names")
            }
            guard offer.basemapIsVector else {
                return MapTypeOption(type: type, isAvailable: false,
                                     detail: "this map is a picture: its roads cannot be drawn over \(imagery.name)")
            }
            return MapTypeOption(type: type, isAvailable: true, detail: "\(imagery.name) with the map's roads and names")
        case .terrain:
            guard let terrain = offer.terrain else {
                return MapTypeOption(type: type, isAvailable: false, detail: "this backend has no heights")
            }
            return MapTypeOption(type: type, isAvailable: true, detail: terrain.detail)
        }
    }

    /// Show `type`, if the backend can draw it. Returns whether it did.
    @discardableResult
    public func select(_ type: MapType) -> Bool {
        guard option(for: type).isAvailable else { return false }
        mapType = type
        prepareStores()
        return true
    }

    /// Use the offer's imagery at `index`.
    public func selectImagery(_ index: Int) {
        guard offer.imagery.indices.contains(index) else { return }
        imageryIndex = index
        prepareStores()
    }

    /// A new backend's offer: the type shown is kept where the backend can
    /// draw it, and is Explore where it cannot.
    public func setOffer(_ newOffer: MapTypeOffer) {
        offer = newOffer
        imageryIndex = 0
        imageryKey = nil
        terrainKey = nil
        if !option(for: mapType).isAvailable { mapType = .explore }
        prepareStores()
    }

    /// What the map draws for the type shown, at its ``elevation``.
    public var layers: MapLayers {
        var layers = typeLayers
        if elevation == .realistic {
            layers.elevation = .realistic
            if layers.terrain == nil { layers.terrain = terrainStore }
        }
        return layers
    }

    private var typeLayers: MapLayers {
        switch mapType {
        case .explore:
            return .explore
        case .satellite:
            return MapLayers(imagery: imageryStore, basemap: .hidden)
        case .hybrid:
            let hasOwnLabels = imagery?.hybridSource != nil
            return MapLayers(imagery: imageryStore, basemap: hasOwnLabels ? .hidden : .linesAndLabels)
        case .terrain:
            return MapLayers(terrain: terrainStore)
        }
    }

    /// Give each store the source the type shown draws from.
    private func prepareStores() {
        switch mapType {
        case .explore:
            break
        case .satellite, .hybrid:
            guard let imagery else { return }
            let usesHybrid = mapType == .hybrid && imagery.hybridSource != nil
            let source = usesHybrid ? imagery.hybridSource ?? imagery.source : imagery.source
            let key = "\(imagery.id)\(usesHybrid ? "-hybrid" : "")"
            imageryStore = store(imageryStore, key: key, current: &imageryKey, source: source)
        case .terrain:
            break
        }
        if mapType == .terrain || elevation == .realistic, let terrain = offer.terrain {
            terrainStore = store(terrainStore, key: terrain.id, current: &terrainKey, source: terrain.source)
        }
    }

    private func store(_ existing: MapTileStore?, key: String, current: inout String?,
                       source: any MapTileSource) -> MapTileStore {
        guard let existing else {
            current = key
            return MapTileStore(source: source)
        }
        if current != key {
            existing.replaceSource(source)
            current = key
        }
        return existing
    }
}
