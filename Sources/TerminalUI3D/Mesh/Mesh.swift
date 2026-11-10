import Foundation

/// A surface made of triangles: positions, a normal per position, and the
/// material each triangle is drawn in.
///
/// A triangle's front is the side its corners run anticlockwise on, and
/// only fronts are drawn unless its material is double-sided. Normals are
/// per vertex: a vertex shared by triangles at an angle is a smooth surface
/// there, and a hard edge is made of vertices of its own on each side — as
/// the ``box(width:height:depth:)`` primitive's corners are.
///
/// A vertex's ``tints`` value places it along its material's gradient: a
/// terrain coloured by height, water to snow, is one gradient material and a
/// tint per vertex.
///
/// ```swift
/// let ring = Mesh.torus(majorRadius: 1, minorRadius: 0.4)
/// let block = Mesh.box(width: 1, height: 2, depth: 1).transformed(by: .translation(Vector3(2, 0, 0)))
/// let both = ring.merged(with: block)
/// ```
public struct Mesh: Sendable, Equatable {
    /// One triangle: three indices into the positions, and which of its
    /// model's materials it is drawn in.
    public struct Triangle: Sendable, Hashable {
        /// The first corner.
        public var first: Int
        /// The second corner, anticlockwise from the first seen from the front.
        public var second: Int
        /// The third corner.
        public var third: Int
        /// Which of its model's materials the triangle is drawn in.
        public var material: Int

        /// The triangle of corners `first`, `second`, `third`, anticlockwise
        /// seen from its front, drawn in material `material`.
        public init(_ first: Int, _ second: Int, _ third: Int, material: Int = 0) {
            self.first = first
            self.second = second
            self.third = third
            self.material = material
        }
    }

    /// Where each vertex is.
    public var positions: [Vector3]
    /// Which way the surface faces at each vertex, of length 1.
    public var normals: [Vector3]
    /// Where each vertex lies along its material's gradient, 0 to 1; empty
    /// puts every vertex at 0, the gradient's first colour.
    public var tints: [Double]
    /// The triangles.
    public var triangles: [Triangle]

    /// A mesh of these vertices and triangles. With no `normals`, each
    /// vertex takes the area-weighted average of its triangles' normals.
    public init(positions: [Vector3], normals: [Vector3]? = nil, tints: [Double] = [],
                triangles: [Triangle]) {
        self.positions = positions
        self.tints = tints
        self.triangles = triangles
        self.normals = []
        if let normals, normals.count == positions.count {
            self.normals = normals
        } else {
            self.normals = computedNormals()
        }
    }

    /// The mesh with nothing in it.
    public static let empty = Mesh(positions: [], normals: [], triangles: [])

    /// Each vertex's normal as the area-weighted average of the normals of
    /// the triangles it is a corner of.
    func computedNormals() -> [Vector3] {
        var sums = Array(repeating: Vector3.zero, count: positions.count)
        for triangle in triangles {
            guard positions.indices.contains(triangle.first), positions.indices.contains(triangle.second),
                  positions.indices.contains(triangle.third) else { continue }
            // The cross product's length is twice the triangle's area, so
            // summing it unnormalised weights each face by its area.
            let face = (positions[triangle.second] - positions[triangle.first])
                .cross(positions[triangle.third] - positions[triangle.first])
            sums[triangle.first] += face
            sums[triangle.second] += face
            sums[triangle.third] += face
        }
        return sums.map(\.normalized)
    }

    /// The smallest box holding every vertex, or nil for an empty mesh.
    public var bounds: (minimum: Vector3, maximum: Vector3)? {
        guard var minimum = positions.first else { return nil }
        var maximum = minimum
        for position in positions {
            minimum = Vector3(min(minimum.x, position.x), min(minimum.y, position.y), min(minimum.z, position.z))
            maximum = Vector3(max(maximum.x, position.x), max(maximum.y, position.y), max(maximum.z, position.z))
        }
        return (minimum, maximum)
    }

    /// The mesh moved, turned or scaled by `transform`, normals with it.
    public func transformed(by transform: Matrix4) -> Mesh {
        let normalTransform = transform.normalMatrix
        var moved = self
        moved.positions = positions.map { transform.transformPoint($0) }
        moved.normals = normals.map { normalTransform.transformDirection($0).normalized }
        return moved
    }

    /// The mesh drawn in material `material` throughout.
    public func withMaterial(_ material: Int) -> Mesh {
        var repainted = self
        repainted.triangles = triangles.map { Triangle($0.first, $0.second, $0.third, material: material) }
        return repainted
    }

    /// This mesh and `other` as one, `other`'s triangles keeping their
    /// materials.
    public func merged(with other: Mesh) -> Mesh {
        var merged = self
        let offset = positions.count
        merged.positions += other.positions
        merged.normals += other.normals
        if !tints.isEmpty || !other.tints.isEmpty {
            merged.tints = (tints.isEmpty ? Array(repeating: 0, count: positions.count) : tints)
                + (other.tints.isEmpty ? Array(repeating: 0, count: other.positions.count) : other.tints)
        }
        merged.triangles += other.triangles.map {
            Triangle($0.first + offset, $0.second + offset, $0.third + offset, material: $0.material)
        }
        return merged
    }

    /// The mesh with every vertex at `tint` along its material's gradient.
    public func withTint(_ tint: Double) -> Mesh {
        var tinted = self
        tinted.tints = Array(repeating: tint, count: positions.count)
        return tinted
    }
}

/// Builds a mesh a face at a time, each face's corners its own so its edges
/// stay hard.
struct MeshBuilder {
    var positions: [Vector3] = []
    var normals: [Vector3] = []
    var tints: [Double] = []
    var triangles: [Mesh.Triangle] = []

    /// A flat quad with corners anticlockwise seen from the front.
    mutating func addQuad(_ corners: [Vector3], material: Int, tint: Double = 0) {
        let normal = (corners[1] - corners[0]).cross(corners[2] - corners[0]).normalized
        let base = positions.count
        for corner in corners {
            positions.append(corner)
            normals.append(normal)
            tints.append(tint)
        }
        triangles.append(Mesh.Triangle(base, base + 1, base + 2, material: material))
        triangles.append(Mesh.Triangle(base, base + 2, base + 3, material: material))
    }

    /// A flat quad facing `outward`, its corners in order round it either
    /// way: they are put anticlockwise as seen from that side.
    mutating func addQuad(_ corners: [Vector3], facing outward: Vector3, material: Int, tint: Double = 0) {
        let normal = (corners[1] - corners[0]).cross(corners[2] - corners[0])
        addQuad(normal.dot(outward) < 0 ? corners.reversed() : corners, material: material, tint: tint)
    }

    /// A flat triangle with corners anticlockwise seen from the front.
    mutating func addTriangle(_ first: Vector3, _ second: Vector3, _ third: Vector3, material: Int,
                              tint: Double = 0) {
        let normal = (second - first).cross(third - first).normalized
        let base = positions.count
        for corner in [first, second, third] {
            positions.append(corner)
            normals.append(normal)
            tints.append(tint)
        }
        triangles.append(Mesh.Triangle(base, base + 1, base + 2, material: material))
    }

    /// Triangle (`first`, `second`, `third`) of vertices already added,
    /// wound so its front faces the way their normals do; one with no area
    /// is left out.
    mutating func addSmoothTriangle(_ first: Int, _ second: Int, _ third: Int, material: Int) {
        let face = (positions[second] - positions[first]).cross(positions[third] - positions[first])
        guard face.length > Self.degenerateArea else { return }
        let outward = normals[first] + normals[second] + normals[third]
        triangles.append(face.dot(outward) >= 0
            ? Mesh.Triangle(first, second, third, material: material)
            : Mesh.Triangle(first, third, second, material: material))
    }

    /// Twice the area below which a triangle is a point or a line — a
    /// sphere's pole — and draws nothing.
    static let degenerateArea = 1e-12

    var mesh: Mesh {
        Mesh(positions: positions, normals: normals, tints: tints, triangles: triangles)
    }
}
