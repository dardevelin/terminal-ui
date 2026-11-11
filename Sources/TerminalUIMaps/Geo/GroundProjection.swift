import Foundation
import TerminalUI

/// Where the ground lands on screen: the north-up map, in dots of the
/// viewport at the camera's scale, turned by the camera's bearing about the
/// viewport's middle, then tipped away by its pitch and seen in perspective.
///
/// A plane seen through a pinhole is a homography of the plane (Hartley and
/// Zisserman, *Multiple View Geometry*, 2nd ed., §2.3): what is straight on
/// the ground is straight on screen, so a road is still a polyline of its
/// projected points, a tile's square a quadrilateral of its corners. The eye
/// stands back from the middle of the view by ``eyeDistanceShare`` of the
/// viewport's height, MapLibre's choice: its default vertical field of view
/// is 36.87°, which puts the eye `0.5 / tan(fov / 2)` = 1.5 heights away
/// (MapLibre GL JS, `Transform.cameraToCenterDistance`). Across the middle
/// the scale is a flat camera's, so a zoom means the same whatever the
/// pitch.
///
/// Flat, the projection is the bearing's turn and nothing more, computed as
/// it always was — the same bytes as before pitch existed.
struct GroundProjection: Sendable, Equatable {
    let rotation: MapCamera.Rotation
    let pitchCosine: Double
    let pitchSine: Double
    /// From the eye to the middle of the ground, in dots.
    let eyeDistance: Double
    let middleX: Double
    let middleY: Double

    /// The eye's distance from the middle, in viewport heights.
    static let eyeDistanceShare = 1.5

    /// Ground nearer the eye than this share of its distance to the middle
    /// is not drawn: it lies well below the bottom of the view, and nearer
    /// still the projection runs to infinity.
    static let nearestDrawnShare = 0.1

    /// The depths, in shares of the eye's distance, a point of the screen
    /// is taken back to: below the view nothing nearer than twice the
    /// nearest drawn ground, so whatever is clipped to the view can be
    /// drawn; above it nothing beyond the furthest the top edge reaches at
    /// the steepest pitch (2.4), with room to spare.
    static let groundDepths = (nearest: 2 * nearestDrawnShare, furthest: 4.0)

    init(bearing: Double, pitch: Double, viewport: DotSize) {
        rotation = MapCamera.Rotation(bearing: bearing)
        let radians = GeoMeasure.radians(pitch)
        pitchCosine = pitch == 0 ? 1 : cos(radians)
        pitchSine = pitch == 0 ? 0 : sin(radians)
        // A viewport of no height still has an eye somewhere, so a pitched
        // camera given an empty view divides by nothing.
        eyeDistance = Self.eyeDistanceShare * max(viewport.height, 1)
        middleX = viewport.width / 2
        middleY = viewport.height / 2
    }

    /// No pitch: the ground faces the screen.
    var isFlat: Bool { pitchSine == 0 }

    /// No pitch and no bearing: a point of the ground is the point of the
    /// screen.
    var isAxisAligned: Bool { isFlat && rotation.isIdentity }

    /// Where a north-up point of the ground is drawn, or nil where it lies
    /// too near the eye, or behind it, to be drawn at all.
    func toScreen(x: Double, y: Double) -> (x: Double, y: Double)? {
        let turned = rotation.isIdentity ? (x: x - middleX, y: y - middleY)
            : rotation.toScreen(x: x - middleX, y: y - middleY)
        guard !isFlat else { return (middleX + turned.x, middleY + turned.y) }
        // Ahead of the middle is up the screen, -y; the ground there is
        // tipped away from the eye, so further off.
        let depth = eyeDistance - turned.y * pitchSine
        guard depth >= Self.nearestDrawnShare * eyeDistance else { return nil }
        let scale = eyeDistance / depth
        return (middleX + turned.x * scale, middleY + turned.y * pitchCosine * scale)
    }

    /// The north-up point of the ground drawn at a point of the screen.
    ///
    /// Every point of a view lies below the horizon at the steepest pitch
    /// (the top edge reaches 2.4 eye distances); one far off it, or above
    /// the horizon, is taken back to the ground at the furthest of
    /// ``groundDepths``, below the view to the nearest, along its own
    /// column.
    func toGround(x: Double, y: Double) -> (x: Double, y: Double) {
        let offsetX = x - middleX, offsetY = y - middleY
        var turned: (x: Double, y: Double)
        if isFlat {
            turned = (offsetX, offsetY)
        } else {
            // From y = D·t·cos φ / (D + t·sin φ), solved for t; at the
            // horizon the denominator reaches zero.
            let denominator = eyeDistance * pitchCosine + offsetY * pitchSine
            let nearest = Self.groundDepths.nearest * eyeDistance, furthest = Self.groundDepths.furthest * eyeDistance
            var depth = furthest
            if denominator > 0 {
                let turnedY = offsetY * eyeDistance / denominator
                depth = min(max(eyeDistance - turnedY * pitchSine, nearest), furthest)
            }
            turned = (offsetX * depth / eyeDistance, (eyeDistance - depth) / pitchSine)
        }
        if !rotation.isIdentity { turned = rotation.toMap(x: turned.x, y: turned.y) }
        return (middleX + turned.x, middleY + turned.y)
    }

    /// How many times larger than at the middle a short distance of the
    /// ground at a north-up point is drawn across the screen: 1 flat, less
    /// ahead, more behind.
    func magnification(x: Double, y: Double) -> Double {
        guard !isFlat else { return 1 }
        let turnedY = rotation.isIdentity ? y - middleY : rotation.toScreen(x: x - middleX, y: y - middleY).y
        let depth = max(eyeDistance - turnedY * pitchSine, Self.nearestDrawnShare * eyeDistance)
        return eyeDistance / depth
    }

    /// The zoom a north-up point of the ground is drawn at, by a camera
    /// at `zoom`: the zoom whose flat map has its scale.
    func zoom(_ zoom: Double, atX x: Double, y: Double) -> Double {
        isFlat ? zoom : zoom + log2(magnification(x: x, y: y))
    }

    /// The ground the viewport shows, `margin` dots beyond each edge, as a
    /// convex quadrilateral of north-up points: what a feature is cut to
    /// before it is projected, so nothing behind the eye reaches the screen.
    func footprint(of viewport: DotSize, margin: Double) -> ConvexRegion {
        let left = -margin, top = -margin, right = viewport.width + margin, bottom = viewport.height + margin
        let corners = [(left, top), (right, top), (right, bottom), (left, bottom)].map { corner in
            let point = toGround(x: corner.0, y: corner.1)
            return CanvasPoint(x: point.x, y: point.y)
        }
        return ConvexRegion(corners)
    }
}

/// A convex polygon, and what is cut to it.
struct ConvexRegion: Sendable, Equatable {
    /// The corners, in order round it.
    let corners: [CanvasPoint]
    /// +1 when the corners run clockwise with y down the screen, -1 when
    /// they run the other way: the side of each edge the inside lies on.
    private let winding: Double

    init(_ corners: [CanvasPoint]) {
        self.corners = corners
        var twiceArea = 0.0
        for index in corners.indices {
            let point = corners[index], next = corners[(index + 1) % corners.count]
            twiceArea += point.x * next.y - next.x * point.y
        }
        winding = twiceArea >= 0 ? 1 : -1
    }

    /// The box round it: left, top, right, bottom.
    var bounds: (left: Double, top: Double, right: Double, bottom: Double) {
        (corners.map(\.x).min() ?? 0, corners.map(\.y).min() ?? 0,
         corners.map(\.x).max() ?? 0, corners.map(\.y).max() ?? 0)
    }

    /// How far inside edge `index` a point lies, scaled by the edge's
    /// length: negative outside.
    private func side(_ point: CanvasPoint, edge index: Int) -> Double {
        let start = corners[index], end = corners[(index + 1) % corners.count]
        return winding * ((end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x))
    }

    func contains(_ point: CanvasPoint) -> Bool {
        corners.indices.allSatisfy { side(point, edge: $0) >= 0 }
    }

    /// A ring cut to the region, an edge at a time, by Sutherland and
    /// Hodgman's re-entrant clipping ("Reentrant polygon clipping", CACM
    /// 17(1), 1974). Points on an edge are kept, so a ring that only
    /// touches the region comes back with no area rather than none.
    func clipped(ring: [CanvasPoint]) -> [CanvasPoint] {
        var points = ring
        for edge in corners.indices {
            guard var previous = points.last else { return [] }
            var kept: [CanvasPoint] = []
            kept.reserveCapacity(points.count + 1)
            var previousSide = side(previous, edge: edge)
            for point in points {
                let pointSide = side(point, edge: edge)
                if pointSide >= 0 {
                    if previousSide < 0 { kept.append(Self.crossing(previous, previousSide, point, pointSide)) }
                    kept.append(point)
                } else if previousSide >= 0 {
                    kept.append(Self.crossing(previous, previousSide, point, pointSide))
                }
                previous = point
                previousSide = pointSide
            }
            points = kept
        }
        return points
    }

    /// The runs of a line inside the region: each segment cut to it by
    /// Cyrus and Beck's parametric test ("Generalized two- and
    /// three-dimensional clipping", Computers & Graphics 3(1), 1978), a
    /// run ending where the line leaves and a new one starting where it
    /// comes back.
    func runs(of line: [CanvasPoint]) -> [[CanvasPoint]] {
        var runs: [[CanvasPoint]] = []
        var current: [CanvasPoint] = []
        for (start, end) in zip(line, line.dropFirst()) {
            var entering = 0.0, leaving = 1.0
            var visible = true
            for edge in corners.indices {
                let startSide = side(start, edge: edge), endSide = side(end, edge: edge)
                if startSide < 0, endSide < 0 {
                    visible = false
                    break
                }
                if startSide < 0 {
                    entering = max(entering, startSide / (startSide - endSide))
                } else if endSide < 0 {
                    leaving = min(leaving, startSide / (startSide - endSide))
                }
            }
            guard visible, entering <= leaving else {
                if !current.isEmpty { runs.append(current) }
                current = []
                continue
            }
            let from = Self.point(start, end, at: entering), to = Self.point(start, end, at: leaving)
            if current.isEmpty || entering > 0 {
                if current.count >= 2 { runs.append(current) }
                current = [from]
            }
            current.append(to)
            if leaving < 1 {
                runs.append(current)
                current = []
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    private static func point(_ start: CanvasPoint, _ end: CanvasPoint,
                              at fraction: Double) -> CanvasPoint {
        CanvasPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
    }

    private static func crossing(_ start: CanvasPoint, _ startSide: Double, _ end: CanvasPoint,
                                 _ endSide: Double) -> CanvasPoint {
        point(start, end, at: startSide / (startSide - endSide))
    }
}
