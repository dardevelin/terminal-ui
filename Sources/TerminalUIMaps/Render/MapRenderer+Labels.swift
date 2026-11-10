import TerminalUI

/// A point of interest a frame drew: what it is, where it is, and the
/// cells its glyph and name took — what a click on the map is matched
/// against.
public struct MapPointOfInterest: Sendable, Hashable {
    public var name: String
    public var category: PointOfInterestCategory
    /// OpenMapTiles' `class` and `subclass`: "shop" and "jewelry",
    /// "restaurant" and "restaurant".
    public var featureClass: String
    public var subclass: String?
    /// The vector tile feature's id, which some sources tie to the map
    /// data's own (``OSMElement/init(openMapTilesFeatureID:)``).
    public var featureID: UInt64?
    public var coordinate: GeoCoordinate
    /// The glyph's cell.
    public var column: Int
    public var row: Int
    /// The columns its name took on the glyph's row or beside it, nil
    /// where only the glyph found room.
    public var nameColumns: Range<Int>?
    public var nameRow: Int?

    public init(name: String, category: PointOfInterestCategory, featureClass: String, subclass: String? = nil,
                featureID: UInt64? = nil, coordinate: GeoCoordinate, column: Int, row: Int,
                nameColumns: Range<Int>? = nil, nameRow: Int? = nil) {
        self.name = name
        self.category = category
        self.featureClass = featureClass
        self.subclass = subclass
        self.featureID = featureID
        self.coordinate = coordinate
        self.column = column
        self.row = row
        self.nameColumns = nameColumns
        self.nameRow = nameRow
    }

    /// Whether the cell at `column`, `row` is the glyph's or its name's.
    public func contains(column: Int, row: Int) -> Bool {
        if column == self.column && row == self.row { return true }
        guard let nameColumns, let nameRow else { return false }
        return row == nameRow && nameColumns.contains(column)
    }
}

extension MapRenderer {
    /// The point of interest the last frame drew at a cell of the canvas —
    /// its glyph or its name — or nil.
    public func pointOfInterest(atColumn column: Int, row: Int) -> MapPointOfInterest? {
        placedPointsOfInterest.first { $0.contains(column: column, row: row) }
    }

    private enum Glyphs {
        /// A marker's pin.
        static let marker = "●"
    }

    /// Ranks are a role's place in `MapRole.labelPriority` times this, plus
    /// the feature's own rank within its role, so a role's names keep
    /// together and its important ones come first.
    private static let rankStride = 1_000

    /// A line's names: the road's class, ten apart, then how far out from
    /// the middle the name is, so a road's middle is named before its ends
    /// and a bigger road before a smaller one.
    private static let lineRankStep = 10

    /// The rank a marker's title claims space at: before every name of the
    /// basemap's.
    private static let markerRank = -1

    private enum LineNames {
        /// Columns between one name along a line and the next: a long
        /// street is named again a screen's third further on, wide enough
        /// apart that the repeats read as one street's.
        static let interval = 40
        /// A name longer than the line it names would be read as naming
        /// something else: a lane, or a river at a zoom where the town is
        /// a few cells wide, goes unnamed until it is as long as its name.
        static let shortestNamedShare = 1.0
    }

    /// The middle of a cell, from its corner.
    private static let cellMiddle = 0.5

    /// What a request offered to the placer stands for.
    private enum Offered {
        /// The traveller's own cell, claimed with an empty name so no label
        /// is drawn over where they are.
        case traveller
        case marker
        case name(MapRole)
        case pointOfInterest(TileLabel, TileID)
    }

    /// Names, points of interest, markers and the traveller over the
    /// basemap. `background`, where given, is the ground every name and
    /// glyph is set on — the theme's own, over a satellite picture, as a
    /// hybrid map sets its names on a plate — so text reads over any photo.
    func drawLabels(_ items: [Item], content: [MapElement], camera: MapCamera, projection: Projection,
                    size: CanvasSize, context: GraphicsContext, theme: any Theme, background: Color?) {
        var requests: [LabelRequest] = []
        var offered: [Offered] = []
        let viewport = projection.viewport
        let cellWidth = Double(BrailleCell.dotColumns), cellHeight = Double(BrailleCell.dotRows)
        func onScreen(_ x: Double, _ y: Double) -> Bool {
            x >= 0 && x < viewport.width && y >= 0 && y < viewport.height
        }
        func cell(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: x / cellWidth, y: y / cellHeight) }
        var travellers: [(cell: CanvasPoint, glyph: String)] = []
        for case .traveller(let traveller) in content {
            let point = camera.screenPoint(for: traveller.coordinate, in: viewport)
            guard onScreen(point.x, point.y) else { continue }
            let cell = CanvasPoint(x: (point.x / cellWidth).rounded(.down), y: (point.y / cellHeight).rounded(.down))
            travellers.append((cell, TravellerMarker.glyph(course: traveller.course, bearing: camera.bearing)))
            requests.append(LabelRequest(text: " ", anchor: CanvasPoint(x: cell.x + Self.cellMiddle,
                                                                        y: cell.y + Self.cellMiddle),
                                         rank: Self.markerRank - 1, style: .centred))
            offered.append(.traveller)
        }
        var markerCells: [CanvasPoint] = []
        for case .marker(let marker) in content {
            let point = camera.screenPoint(for: marker.coordinate, in: viewport)
            guard onScreen(point.x, point.y) else { continue }
            let anchor = cell(point.x, point.y)
            markerCells.append(anchor)
            requests.append(LabelRequest(text: marker.title, anchor: anchor, rank: Self.markerRank,
                                         style: .besideMarker))
            offered.append(.marker)
        }
        var cut = 0
        for item in items {
            guard case .vector(let vector) = item.tile.content else { continue }
            let maximumRank = pointOfInterestDensity.maximumRank(atZoom: camera.zoom, tileZoom: item.tile.id.zoom)
            for label in vector.labels where label.role.isVisible(atZoom: camera.zoom) {
                if label.pointOfInterest != nil, label.importance > maximumRank {
                    cut += 1
                    continue
                }
                let northUpX = item.originX + label.x * item.side, northUpY = item.originY + label.y * item.side
                guard item.covers(x: northUpX, y: northUpY) else { continue }
                // Turned to where the bearing puts the point; the name
                // stays level, as text on a screen must.
                let (x, y) = projection.turned(x: northUpX, y: northUpY)
                guard onScreen(x, y) else { continue }
                let rank = (label.role.labelRank ?? 0) * Self.rankStride
                    + min(max(label.importance, 0), Self.rankStride - 1)
                if label.pointOfInterest != nil {
                    requests.append(LabelRequest(text: label.text, anchor: cell(x, y), rank: rank,
                                                 style: .pointOfInterest))
                    offered.append(.pointOfInterest(label, item.tile.id))
                } else {
                    requests.append(LabelRequest(text: label.text, anchor: cell(x, y), rank: rank, style: .centred))
                    offered.append(.name(label.role))
                }
            }
            for line in vector.lineLabels where line.role.isVisible(atZoom: camera.zoom) {
                let anchors = lineAnchors(line, in: item, projection: projection)
                for (index, anchor) in anchors.enumerated() {
                    let rank = (line.role.labelRank ?? 0) * Self.rankStride
                        + min(max(line.importance, 0) * Self.lineRankStep + min(index, Self.lineRankStep - 1),
                              Self.rankStride - 1)
                    requests.append(LabelRequest(text: line.text, anchor: cell(anchor.x, anchor.y), rank: rank,
                                                 style: .centred))
                    offered.append(.name(line.role))
                }
            }
        }
        statistics.pointsOfInterestCut = cut
        statistics.labelsOffered = requests.count
        let placed = labelPlacer.place(requests, in: Size(width: Int(size.width), height: Int(size.height)))
        placedLabels = placed
        statistics.labelsPlaced = placed.count

        var pointsOfInterest: [MapPointOfInterest] = []
        for label in placed {
            guard case .pointOfInterest(let tileLabel, let tileID) = offered[label.request],
                  let kind = tileLabel.pointOfInterest else { continue }
            let anchor = requests[label.request].anchor
            let column = Int(anchor.x.rounded(.down)), row = Int(anchor.y.rounded(.down))
            context.draw(Text(TextSpan(kind.category.glyph, foreground: kind.category.colour(in: theme),
                                       background: background, bold: true)),
                         at: CanvasPoint(x: Double(column), y: Double(row)), anchor: .topLeading)
            let count = Double(TileID.tilesPerSide(atZoom: tileID.zoom))
            let coordinate = WebMercator.unproject(WorldPoint(x: (Double(tileID.x) + tileLabel.x) / count,
                                                              y: (Double(tileID.y) + tileLabel.y) / count))
            pointsOfInterest.append(MapPointOfInterest(
                name: tileLabel.text, category: kind.category, featureClass: kind.featureClass,
                subclass: kind.subclass, featureID: kind.featureID, coordinate: coordinate, column: column, row: row,
                nameColumns: label.showsText ? label.column..<(label.column + label.width) : nil,
                nameRow: label.showsText ? label.row : nil))
        }
        placedPointsOfInterest = pointsOfInterest
        statistics.pointsOfInterestPlaced = pointsOfInterest.count

        for cell in markerCells {
            context.draw(Text(TextSpan(Glyphs.marker, foreground: theme.accent, bold: true)),
                         at: CanvasPoint(x: cell.x.rounded(.down), y: cell.y.rounded(.down)), anchor: .topLeading)
        }
        for traveller in travellers {
            context.draw(Text(TextSpan(traveller.glyph, foreground: theme.foregroundEmphasis, background: theme.info,
                                       bold: true)),
                         at: traveller.cell, anchor: .topLeading)
        }
        for label in placed where label.showsText {
            if case .traveller = offered[label.request] { continue }
            let role: MapRole? = switch offered[label.request] {
            case .traveller, .marker: nil
            case .name(let role): role
            case .pointOfInterest: .poiLabel
            }
            let span = TextSpan(label.text,
                                foreground: role.map { $0.colour(in: theme) } ?? theme.foregroundEmphasis,
                                background: background, bold: role.map(\.isBoldLabel) ?? true)
            context.draw(Text(span), at: CanvasPoint(x: Double(label.column), y: Double(label.row)),
                         anchor: .topLeading)
        }
    }

    /// Where a line's name is offered this frame, in dots, in the order
    /// they claim space: every ``LineNames/interval`` columns along the
    /// line out from its middle, those on screen; and where none is, the
    /// middle of the longest stretch the screen shows, so a street that
    /// crosses the view is named however close the camera is.
    private func lineAnchors(_ line: LineLabel, in item: Item, projection: Projection) -> [(x: Double, y: Double)] {
        let side = item.side, originX = item.originX, originY = item.originY
        let viewport = projection.viewport, reach = projection.reach
        guard originX + line.maximumX * side >= reach.left, originX + line.minimumX * side <= reach.right,
              originY + line.maximumY * side >= reach.top, originY + line.minimumY * side <= reach.bottom else {
            return []
        }
        let cellWidth = Double(BrailleCell.dotColumns)
        let textDots = Double(labelPlacer.width(of: line.text)) * cellWidth
        let lengthDots = line.length * side
        guard textDots > 0, lengthDots >= textDots * LineNames.shortestNamedShare else { return [] }
        /// A point of the line north up, in dots, and where the bearing
        /// turns it on screen.
        func screen(_ point: (x: Double, y: Double)) -> (northUpX: Double, northUpY: Double, x: Double, y: Double) {
            let northUpX = originX + point.x * side, northUpY = originY + point.y * side
            let turned = projection.turned(x: northUpX, y: northUpY)
            return (northUpX, northUpY, turned.x, turned.y)
        }
        func shows(_ point: (northUpX: Double, northUpY: Double, x: Double, y: Double)) -> Bool {
            point.x >= 0 && point.x < viewport.width && point.y >= 0 && point.y < viewport.height
                && item.covers(x: point.northUpX, y: point.northUpY)
        }
        let interval = max(Double(LineNames.interval) * cellWidth, textDots + cellWidth) / side
        let middle = line.length / 2
        let steps = Int((middle / interval).rounded(.down))
        var anchors: [(x: Double, y: Double)] = []
        for step in 0...steps {
            for distance in step == 0 ? [middle] : [middle - Double(step) * interval, middle + Double(step) * interval] {
                let point = screen(line.point(at: distance))
                if shows(point) { anchors.append((point.x, point.y)) }
            }
        }
        if anchors.isEmpty, let stretch = longestVisibleStretch(of: line, in: item, projection: projection) {
            let point = screen(line.point(at: (stretch.lowerBound + stretch.upperBound) / 2))
            if shows(point) { anchors.append((point.x, point.y)) }
        }
        return anchors
    }

    /// The longest run of the line inside the viewport, as distances along
    /// it in the unit square: each segment clipped to the viewport by
    /// Liang and Barsky's parametric test ("A new concept and method for
    /// line clipping", ACM TOG 3(1), 1984).
    private func longestVisibleStretch(of line: LineLabel, in item: Item,
                                       projection: Projection) -> ClosedRange<Double>? {
        let viewport = projection.viewport
        var best: ClosedRange<Double>?
        var current: ClosedRange<Double>?
        for index in 1..<line.xs.count {
            // Turned first: a turn keeps a point's share of the way along a
            // segment, so the clip's fractions are the line's.
            let (startX, startY) = projection.turned(x: item.originX + line.xs[index - 1] * item.side,
                                                     y: item.originY + line.ys[index - 1] * item.side)
            let (endX, endY) = projection.turned(x: item.originX + line.xs[index] * item.side,
                                                 y: item.originY + line.ys[index] * item.side)
            let deltaX = endX - startX, deltaY = endY - startY
            var entering = 0.0, leaving = 1.0
            let edges = [(-deltaX, startX), (deltaX, viewport.width - startX),
                         (-deltaY, startY), (deltaY, viewport.height - startY)]
            var inside = true
            for (direction, distance) in edges {
                if direction == 0 {
                    if distance < 0 { inside = false }
                    continue
                }
                let crossing = distance / direction
                if direction < 0 { entering = max(entering, crossing) } else { leaving = min(leaving, crossing) }
            }
            let segmentStart = line.distances[index - 1], segmentLength = line.distances[index] - segmentStart
            if inside, entering < leaving {
                let visible = (segmentStart + entering * segmentLength)...(segmentStart + leaving * segmentLength)
                if let run = current, run.upperBound >= visible.lowerBound {
                    current = run.lowerBound...visible.upperBound
                } else {
                    current = visible
                }
            } else {
                current = nil
            }
            if let run = current, run.upperBound - run.lowerBound > (best.map { $0.upperBound - $0.lowerBound } ?? 0) {
                best = run
            }
        }
        return best
    }
}
