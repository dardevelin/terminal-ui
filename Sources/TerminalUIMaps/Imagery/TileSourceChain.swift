import TerminalUIIO

/// Several sources as one: a tile comes from the first that has it, so a
/// detailed regional source can lead and a world-wide one fill in — USGS's
/// imagery in the United States, Sentinel-2 everywhere else.
///
/// Its zooms run to the deepest of its sources'. A source asked deeper
/// than its own last zoom answers from that zoom, its tile cut to the
/// share the deeper tile covers: so a shallower source fills in at every
/// zoom the chain offers, not only at those it has. The tiles so cut from
/// are kept, a few at a time, so the sixteen tiles two zooms in fetch
/// their ancestor once.
///
/// ```swift
/// let imagery = TileSourceChain([RasterTileSource.usgsImagery(), RasterTileSource.sentinel2Cloudless2016()])
/// ```
actor TileSourceChain: MapTileSource {
    private let sources: [any MapTileSource]
    private let name: String?
    private var descriptions: [TileSourceInfo]?
    private var ancestors: [AncestorKey: MapTile] = [:]
    private var ancestorOrder: [AncestorKey] = []

    /// How many ancestor tiles are kept to cut deeper tiles from.
    static let ancestorCapacity = 16

    private struct AncestorKey: Hashable {
        var source: Int
        var tile: TileID
    }

    /// - Parameters:
    ///   - sources: In the order they are asked, the first to answer wins.
    ///   - name: What the chain is called; its sources' names joined
    ///     unless given.
    init(_ sources: [any MapTileSource], name: String? = nil) {
        self.sources = sources
        self.name = name
    }

    func info() async throws -> TileSourceInfo {
        let infos = try await describe()
        guard let first = infos.first else {
            throw MapServiceError.unsupported("a chain of no sources")
        }
        let deepest = infos.map(\.zoomRange.upperBound).max() ?? first.zoomRange.upperBound
        let shallowest = infos.map(\.zoomRange.lowerBound).min() ?? first.zoomRange.lowerBound
        let bounds = infos.dropFirst().reduce(first.bounds) { union, info in
            GeoRect(south: min(union.south, info.bounds.south), west: min(union.west, info.bounds.west),
                    north: max(union.north, info.bounds.north), east: max(union.east, info.bounds.east))
        }
        return TileSourceInfo(name: name ?? infos.map(\.name).joined(separator: " + "),
                              attribution: infos.map(\.attribution).joined(separator: " · "),
                              zoomRange: shallowest...deepest, bounds: bounds)
    }

    func tile(_ id: TileID) async throws -> MapTile? {
        let infos = try await describe()
        var lastError: (any Error)?
        for (index, source) in sources.enumerated() {
            // A request cancelled reaches the next source as a URL error,
            // not a CancellationError: ask no further once the tile is
            // given up.
            try Task.checkCancellation()
            let info = infos[index]
            guard id.bounds.intersects(info.bounds), id.zoom >= info.zoomRange.lowerBound else { continue }
            do {
                if id.zoom <= info.zoomRange.upperBound {
                    if let tile = try await source.tile(id) { return tile }
                } else if let tile = try await descendant(id, of: index, source: source,
                                                          atZoom: info.zoomRange.upperBound) {
                    return tile
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    /// `id` cut from its ancestor at `zoom` in source `index`.
    private func descendant(_ id: TileID, of index: Int, source: any MapTileSource,
                            atZoom zoom: Int) async throws -> MapTile? {
        let ancestorID = id.ancestor(atZoom: zoom)
        let key = AncestorKey(source: index, tile: ancestorID)
        let ancestor: MapTile
        if let kept = ancestors[key] {
            ancestor = kept
        } else {
            guard let fetched = try await source.tile(ancestorID) else { return nil }
            keep(fetched, as: key)
            ancestor = fetched
        }
        return ancestor.descendant(id, of: ancestorID)
    }

    private func keep(_ tile: MapTile, as key: AncestorKey) {
        if ancestors[key] == nil { ancestorOrder.append(key) }
        ancestors[key] = tile
        while ancestorOrder.count > Self.ancestorCapacity {
            ancestors[ancestorOrder.removeFirst()] = nil
        }
    }

    private func describe() async throws -> [TileSourceInfo] {
        if let descriptions { return descriptions }
        var infos: [TileSourceInfo] = []
        for source in sources {
            infos.append(try await source.info())
        }
        descriptions = infos
        return infos
    }
}

extension MapTile {
    /// The share of this tile, `ancestor`, that its descendant `id`
    /// covers: a picture's pixels or a terrain's heights, at the samples
    /// the share has (at least one a side). A vector tile is not cut: it
    /// is drawn over-zoomed instead, and answers nil.
    func descendant(_ id: TileID, of ancestor: TileID) -> MapTile? {
        let shift = id.zoom - ancestor.zoom
        guard shift >= 0, id.ancestor(atZoom: ancestor.zoom) == ancestor else { return nil }
        let span = 1 << shift
        let column = id.x - ancestor.x << shift, row = id.y - ancestor.y << shift
        switch content {
        case .vector:
            return nil
        case .raster(let image):
            let side = max(1, image.width / span), sideDown = max(1, image.height / span)
            let left = min(column * image.width / span, image.width - side)
            let top = min(row * image.height / span, image.height - sideDown)
            var rgba: [UInt8] = []
            rgba.reserveCapacity(side * sideDown * Self.rgbaChannels)
            for y in top..<(top + sideDown) {
                let start = (y * image.width + left) * Self.rgbaChannels
                rgba += image.rgba[start..<(start + side * Self.rgbaChannels)]
            }
            return (try? ImageBuffer(rgba: rgba, width: side, height: sideDown)).map(MapTile.raster)
        case .elevation(let elevation):
            let unit = 1 / Double(span)
            return .elevation(elevation.cropped(unitX: Double(column) * unit, y: Double(row) * unit, side: unit,
                                                samples: max(1, elevation.width / span)))
        }
    }

    /// `ImageBuffer`'s layout: red, green, blue, alpha.
    private static let rgbaChannels = 4
}
