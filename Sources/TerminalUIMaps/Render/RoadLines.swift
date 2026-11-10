import Foundation

extension RenderTile {
    /// The lines of `roles` this tile holds within `radius` metres of
    /// `coordinate`, as coordinates: what a junction's roads are read from
    /// (``JunctionAnalysis/branches(at:lines:rules:)``). A ring whose
    /// bounds lie farther off is passed over.
    func lines(of roles: Set<MapRole>, near coordinate: GeoCoordinate, within radius: Double)
        -> [[GeoCoordinate]] {
        guard case .vector(let vector) = content else { return [] }
        let count = Double(TileID.tilesPerSide(atZoom: id.zoom))
        let world = WebMercator.project(coordinate)
        let metresPerUnit = WebMercator.metresPerWorldUnit(atLatitude: coordinate.latitude) / count
        guard metresPerUnit > 0 else { return [] }
        let reach = radius / metresPerUnit
        let x = world.x * count - Double(id.x), y = world.y * count - Double(id.y)
        var lines: [[GeoCoordinate]] = []
        for layer in vector.layers where roles.contains(layer.role) {
            for (ring, bounds) in layer.ringBounds.enumerated()
                where bounds.minimumX - reach <= x && x <= bounds.maximumX + reach
                && bounds.minimumY - reach <= y && y <= bounds.maximumY + reach {
                let points = (layer.ringStart(ring)..<layer.ringEnds[ring]).map { index in
                    WebMercator.unproject(WorldPoint(x: (Double(id.x) + layer.xs[index]) / count,
                                                     y: (Double(id.y) + layer.ys[index]) / count))
                }
                if points.count >= 2 { lines.append(points) }
            }
        }
        return lines
    }
}

extension MapTileStore {
    /// The lines of `roles` within `radius` metres of `coordinate`, from
    /// the deepest zoom whose tile there the store holds, and that zoom's
    /// neighbours the circle reaches into when they are held too.
    func lines(near coordinate: GeoCoordinate, within radius: Double, roles: Set<MapRole>)
        -> [[GeoCoordinate]] {
        let held = cachedTiles
        guard let zoom = held.filter({ TileID(containing: coordinate, zoom: $0.zoom) == $0 }).map(\.zoom).max()
        else { return [] }
        // The square around the circle: its south-west and north-east
        // corners, a diagonal's half from the middle.
        let corners = [Self.southWest, Self.northEast].map { bearing in
            GeoMeasure.destination(from: coordinate, bearing: bearing, distance: radius * 2.squareRoot())
        }
        let box = GeoRect(south: corners[0].latitude, west: corners[0].longitude,
                          north: corners[1].latitude, east: corners[1].longitude)
        return TileID.covering(box, zoom: zoom).filter(held.contains).flatMap { id in
            tile(id)?.lines(of: roles, near: coordinate, within: radius) ?? []
        }
    }

    private nonisolated static let southWest = 225.0
    private nonisolated static let northEast = 45.0
}
