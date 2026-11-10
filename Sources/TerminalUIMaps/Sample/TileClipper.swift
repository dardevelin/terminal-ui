/// A point in a tile's coordinates before rounding.
struct TileSpacePoint: Sendable, Equatable {
    var x: Double
    var y: Double
}

/// Clips geometry to a tile and the buffer around it, as a tile server
/// cuts features at its tile edges: the buffer lets a line's stroke and a
/// polygon's edge run on past the tile so neighbours join without a seam.
struct TileClipper {
    let minimum: Double
    let maximum: Double

    init(extent: Int, buffer: Int) {
        minimum = -Double(buffer)
        maximum = Double(extent + buffer)
    }

    func contains(_ point: TileSpacePoint) -> Bool {
        (minimum...maximum).contains(point.x) && (minimum...maximum).contains(point.y)
    }

    /// A ring clipped by Sutherland–Hodgman (1974): against each of the four
    /// edges in turn, keeping what is inside and adding the crossing points.
    /// A ring that leaves and re-enters may gain edges along the border,
    /// which a fill does not show.
    func clip(ring: [TileSpacePoint]) -> [TileSpacePoint] {
        var output = ring
        for edge in Edge.allCases {
            guard !output.isEmpty else { return [] }
            let input = output
            output = []
            var previous = input[input.count - 1]
            for point in input {
                let pointInside = inside(point, edge)
                if pointInside != inside(previous, edge) {
                    output.append(crossing(previous, point, edge))
                }
                if pointInside { output.append(point) }
                previous = point
            }
        }
        return output
    }

    /// A polyline clipped by Liang–Barsky (1984) segment by segment; where it
    /// leaves the box and comes back, it becomes two lines.
    func clip(line: [TileSpacePoint]) -> [[TileSpacePoint]] {
        var lines: [[TileSpacePoint]] = []
        var current: [TileSpacePoint] = []
        for (start, end) in zip(line, line.dropFirst()) {
            guard let (clippedStart, clippedEnd) = clip(segmentFrom: start, to: end) else {
                if current.count >= 2 { lines.append(current) }
                current = []
                continue
            }
            if current.last != clippedStart {
                if current.count >= 2 { lines.append(current) }
                current = [clippedStart]
            }
            current.append(clippedEnd)
            if clippedEnd != end {
                lines.append(current)
                current = []
            }
        }
        if current.count >= 2 { lines.append(current) }
        return lines
    }

    private enum Edge: CaseIterable {
        case left, right, top, bottom
    }

    private func inside(_ point: TileSpacePoint, _ edge: Edge) -> Bool {
        switch edge {
        case .left: point.x >= minimum
        case .right: point.x <= maximum
        case .top: point.y >= minimum
        case .bottom: point.y <= maximum
        }
    }

    private func crossing(_ from: TileSpacePoint, _ to: TileSpacePoint, _ edge: Edge) -> TileSpacePoint {
        switch edge {
        case .left, .right:
            let boundary = edge == .left ? minimum : maximum
            let fraction = (boundary - from.x) / (to.x - from.x)
            return TileSpacePoint(x: boundary, y: from.y + (to.y - from.y) * fraction)
        case .top, .bottom:
            let boundary = edge == .top ? minimum : maximum
            let fraction = (boundary - from.y) / (to.y - from.y)
            return TileSpacePoint(x: from.x + (to.x - from.x) * fraction, y: boundary)
        }
    }

    private func clip(segmentFrom start: TileSpacePoint,
                      to end: TileSpacePoint) -> (TileSpacePoint, TileSpacePoint)? {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        var entering = 0.0
        var leaving = 1.0
        let constraints = [(-deltaX, start.x - minimum), (deltaX, maximum - start.x),
                           (-deltaY, start.y - minimum), (deltaY, maximum - start.y)]
        for (direction, distance) in constraints {
            if direction == 0 {
                if distance < 0 { return nil }
                continue
            }
            let fraction = distance / direction
            if direction < 0 {
                entering = max(entering, fraction)
            } else {
                leaving = min(leaving, fraction)
            }
            if entering > leaving { return nil }
        }
        let clippedStart = entering == 0 ? start
            : TileSpacePoint(x: start.x + deltaX * entering, y: start.y + deltaY * entering)
        let clippedEnd = leaving == 1 ? end
            : TileSpacePoint(x: start.x + deltaX * leaving, y: start.y + deltaY * leaving)
        return (clippedStart, clippedEnd)
    }
}
