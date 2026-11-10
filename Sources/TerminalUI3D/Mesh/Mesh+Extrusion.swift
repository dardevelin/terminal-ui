import Foundation

/// A flat shape with holes: an outline, and outlines cut out of it — a
/// building's footprint round its courtyard.
///
/// Either winding will do for any ring; the outline is taken as the
/// outside and every hole as a hole. Holes must lie inside the outline and
/// not cross it or each other.
public struct Polygon2D: Sendable, Equatable {
    /// The outside.
    public var outer: [Vector2]
    /// The parts cut out of it.
    public var holes: [[Vector2]]

    /// The shape inside `outer` and outside every one of `holes`.
    public init(_ outer: [Vector2], holes: [[Vector2]] = []) {
        self.outer = outer
        self.holes = holes
    }

    /// The area a ring encloses, positive when it runs anticlockwise
    /// (the shoelace formula).
    static func signedArea(_ ring: [Vector2]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var twice = 0.0
        for index in ring.indices {
            twice += ring[index].cross(ring[(index + 1) % ring.count])
        }
        return twice / 2
    }

    /// The shape as triangles: the outline with every hole spliced into it,
    /// and index triples into those vertices, each anticlockwise.
    ///
    /// Ear clipping, each hole first joined to the outline by a bridge to a
    /// vertex it can see (Eberly, "Triangulation by Ear Clipping", Geometric
    /// Tools, 2002) — O(n²) in the vertices, which a footprint has few of.
    func triangulate() -> (vertices: [Vector2], triangles: [(Int, Int, Int)]) {
        var ring = Self.signedArea(outer) < 0 ? Array(outer.reversed()) : outer
        ring = Self.withoutRepeats(ring)
        guard ring.count >= 3 else { return (ring, []) }
        let orderedHoles = holes
            .map { Self.withoutRepeats(Self.signedArea($0) > 0 ? Array($0.reversed()) : $0) }
            .filter { $0.count >= 3 }
            .sorted { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }
        for hole in orderedHoles {
            ring = Self.bridge(hole, into: ring)
        }
        return (ring, Self.clipEars(ring))
    }

    /// Positions with consecutive duplicates removed, the closing one too.
    private static func withoutRepeats(_ ring: [Vector2]) -> [Vector2] {
        var kept: [Vector2] = []
        for point in ring where kept.last != point { kept.append(point) }
        if kept.count > 1, kept.first == kept.last { kept.removeLast() }
        return kept
    }

    /// `ring` with `hole` spliced in: from the hole's rightmost vertex
    /// along a bridge to an outline vertex it can see, round the hole, and
    /// back.
    private static func bridge(_ hole: [Vector2], into ring: [Vector2]) -> [Vector2] {
        guard let holeStart = hole.indices.max(by: { hole[$0].x < hole[$1].x }) else { return ring }
        let origin = hole[holeStart]
        // The nearest crossing of a ray from the hole vertex toward +x with
        // the outline, and the edge it crosses.
        var nearest = Double.infinity
        var candidate: Int?
        for index in ring.indices {
            let from = ring[index], to = ring[(index + 1) % ring.count]
            guard (from.y <= origin.y && to.y >= origin.y) || (to.y <= origin.y && from.y >= origin.y),
                  from.y != to.y else { continue }
            let crossingX = from.x + (origin.y - from.y) * (to.x - from.x) / (to.y - from.y)
            guard crossingX >= origin.x, crossingX < nearest else { continue }
            nearest = crossingX
            candidate = from.x > to.x ? index : (index + 1) % ring.count
        }
        guard var visible = candidate else { return ring }
        // A reflex vertex inside the triangle the ray, the crossing and the
        // candidate span would hide the candidate: take the one nearest the
        // ray's direction instead.
        let crossing = Vector2(nearest, origin.y)
        let target = ring[visible]
        var bestAngle = Double.infinity
        for index in ring.indices where index != visible {
            let point = ring[index]
            guard isReflex(ring, index), contains(point, in: (origin, crossing, target)) else { continue }
            let direction = point - origin
            let angle = abs(atan2(direction.y, direction.x))
            if angle < bestAngle {
                bestAngle = angle
                visible = index
            }
        }
        var spliced = Array(ring[...visible])
        for step in 0...hole.count {
            spliced.append(hole[(holeStart + step) % hole.count])
        }
        spliced.append(ring[visible])
        spliced.append(contentsOf: ring[(visible + 1)...])
        return spliced
    }

    private static func isReflex(_ ring: [Vector2], _ index: Int) -> Bool {
        let previous = ring[(index + ring.count - 1) % ring.count]
        let next = ring[(index + 1) % ring.count]
        return (ring[index] - previous).cross(next - ring[index]) < 0
    }

    private static func contains(_ point: Vector2, in triangle: (Vector2, Vector2, Vector2)) -> Bool {
        let (first, second, third) = triangle
        let side1 = (second - first).cross(point - first)
        let side2 = (third - second).cross(point - second)
        let side3 = (first - third).cross(point - third)
        let hasNegative = side1 < 0 || side2 < 0 || side3 < 0
        let hasPositive = side1 > 0 || side2 > 0 || side3 > 0
        return !(hasNegative && hasPositive)
    }

    private static func clipEars(_ ring: [Vector2]) -> [(Int, Int, Int)] {
        var remaining = Array(ring.indices)
        var triangles: [(Int, Int, Int)] = []
        var misses = 0
        var position = 0
        while remaining.count > 3, misses <= remaining.count {
            let count = remaining.count
            let previous = remaining[(position + count - 1) % count]
            let current = remaining[position % count]
            let next = remaining[(position + 1) % count]
            let first = ring[previous], second = ring[current], third = ring[next]
            let convex = (second - first).cross(third - second) > 0
            var isEar = convex
            if convex {
                for other in remaining where other != previous && other != current && other != next {
                    let point = ring[other]
                    // A bridge visits its two ends twice; those copies sit on
                    // the triangle's corners and hide nothing.
                    if point == first || point == second || point == third { continue }
                    if contains(point, in: (first, second, third)) {
                        isEar = false
                        break
                    }
                }
            }
            if isEar {
                triangles.append((previous, current, next))
                remaining.remove(at: position % count)
                misses = 0
            } else {
                position += 1
                misses += 1
            }
            position %= max(1, remaining.count)
        }
        if remaining.count == 3 {
            triangles.append((remaining[0], remaining[1], remaining[2]))
        }
        return triangles
    }
}

extension Mesh {
    /// `polygon`, lying in the ground's x–z plane — its `x` along x and its
    /// `y` along z — raised from `base` to `base + height`: a building from
    /// its footprint, with walls, a roof and a floor.
    ///
    /// - Parameters:
    ///   - material: The walls' material.
    ///   - roofMaterial: The roof's and floor's; nil draws them in
    ///     `material`.
    public static func extrusion(of polygon: Polygon2D, height: Double, base: Double = 0,
                                 material: Int = 0, roofMaterial: Int? = nil) -> Mesh {
        let (vertices, triangles) = polygon.triangulate()
        let capMaterial = roofMaterial ?? material
        var builder = MeshBuilder()
        func place(_ point: Vector2, _ level: Double) -> Vector3 { Vector3(point.x, level, point.y) }
        for (first, second, third) in triangles {
            for (level, outward) in [(base + height, Vector3.unitY), (base, -Vector3.unitY)] {
                let corners = [place(vertices[first], level), place(vertices[second], level),
                               place(vertices[third], level)]
                let normal = (corners[1] - corners[0]).cross(corners[2] - corners[0])
                if normal.dot(outward) >= 0 {
                    builder.addTriangle(corners[0], corners[1], corners[2], material: capMaterial)
                } else {
                    builder.addTriangle(corners[0], corners[2], corners[1], material: capMaterial)
                }
            }
        }
        let outerRing = Polygon2D.signedArea(polygon.outer) < 0 ? Array(polygon.outer.reversed()) : polygon.outer
        let holeRings = polygon.holes.map { Polygon2D.signedArea($0) > 0 ? Array($0.reversed()) : $0 }
        for ring in [outerRing] + holeRings where ring.count >= 2 {
            for index in ring.indices {
                let from = ring[index], to = ring[(index + 1) % ring.count]
                guard from != to else { continue }
                // An anticlockwise outline has the solid on its left, so
                // the outside is on its right; a clockwise hole the same.
                let edge = to - from
                let outward = Vector3(edge.y, 0, -edge.x)
                builder.addQuad([place(from, base), place(to, base), place(to, base + height),
                                 place(from, base + height)],
                                facing: outward, material: material)
            }
        }
        return builder.mesh
    }
}
