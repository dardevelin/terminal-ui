import TerminalUI

extension MapCamera {
    /// The tiles a pitched viewport needs, nearest the centre first: the
    /// ground it shows, each part from the zoom whose tiles draw it at
    /// about the density the camera's own do at the middle.
    ///
    /// The ground ahead recedes, so a tile of the camera's zoom there would
    /// draw its detail in a fraction of the dots: the far ground comes from
    /// coarser tiles, as MapLibre's covering does. A quadtree from the
    /// coarsest zoom any of the view needs splits a tile while the ground
    /// it holds, at its nearest, is drawn larger than its zoom serves, and
    /// never past `nearestZoom`, the zoom a flat camera draws. The tiles
    /// come back without overlaps: each point of the view lies in one.
    func pitchedCoveringTiles(in viewport: DotSize, nearestZoom: Int,
                              sourceZoomRange: ClosedRange<Int>) -> [TileID] {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        let projection = groundProjection(in: viewport)
        let centre = WebMercator.project(center)
        let scale = dotsPerWorld
        let middleX = viewport.width / 2, middleY = viewport.height / 2
        // The view's ground on the unit world, x unwrapped about the centre.
        let footprint = ConvexRegion(projection.footprint(of: viewport, margin: 0).corners.map { corner in
            CanvasPoint(x: centre.x + (corner.x - middleX) / scale, y: centre.y + (corner.y - middleY) / scale)
        })
        /// The zoom a point of the unit world is drawn at.
        func drawnZoom(_ point: CanvasPoint) -> Double {
            projection.zoom(zoom, atX: middleX + (point.x - centre.x) * scale, y: middleY + (point.y - centre.y) * scale)
        }
        /// The source zoom whose tiles draw ground drawn at `drawnZoom` as
        /// densely as the camera's own draw the middle.
        func tileZoom(_ drawnZoom: Double) -> Int {
            min(max(Int(drawnZoom.rounded(.down)), sourceZoomRange.lowerBound), nearestZoom)
        }
        let firstZoom = tileZoom(footprint.corners.map(drawnZoom).min() ?? zoom)

        var found: [(id: TileID, distance: Double)] = []
        var seen: Set<TileID> = []
        /// A tile by its unwrapped column: split while the ground it holds
        /// needs finer, kept once it does not.
        func visit(zoom: Int, column: Int, row: Int) {
            let count = Double(TileID.tilesPerSide(atZoom: zoom))
            let left = Double(column) / count, top = Double(row) / count, side = 1 / count
            let square = [CanvasPoint(x: left, y: top), CanvasPoint(x: left + side, y: top),
                          CanvasPoint(x: left + side, y: top + side), CanvasPoint(x: left, y: top + side)]
            let ground = footprint.clipped(ring: square)
            guard !ground.isEmpty else { return }
            if zoom < tileZoom(ground.map(drawnZoom).max() ?? self.zoom), zoom < TileID.maximumZoom {
                for (childColumn, childRow) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    visit(zoom: zoom + 1, column: column * 2 + childColumn, row: row * 2 + childRow)
                }
                return
            }
            let tilesPerSide = TileID.tilesPerSide(atZoom: zoom)
            let id = TileID(zoom: zoom, x: ((column % tilesPerSide) + tilesPerSide) % tilesPerSide, y: row)
            guard seen.insert(id).inserted else { return }
            let deltaX = left + side / 2 - centre.x, deltaY = top + side / 2 - centre.y
            found.append((id, deltaX * deltaX + deltaY * deltaY))
        }
        let bounds = footprint.bounds
        let count = TileID.tilesPerSide(atZoom: firstZoom)
        let rows = TileID.clampedIndex(bounds.top * Double(count), count: count)
            ... TileID.clampedIndex(bounds.bottom * Double(count), count: count)
        let columns = Int((bounds.left * Double(count)).rounded(.down))...Int((bounds.right * Double(count)).rounded(.down))
        for row in rows {
            for column in columns {
                visit(zoom: firstZoom, column: column, row: row)
            }
        }
        return found.enumerated().sorted { first, second in
            first.element.distance == second.element.distance ? first.offset < second.offset
                : first.element.distance < second.element.distance
        }.map(\.element.id)
    }
}
