import Foundation

// The standard solids, each centred on the origin with y up. Curved ones
// share vertices round their curves, so they shade smooth; flat faces have
// corners of their own, so the edges between them stay hard.

extension Mesh {
    /// A box `width` across x, `height` up y and `depth` along z, every
    /// face drawn in `material`.
    public static func box(width: Double, height: Double, depth: Double, material: Int = 0) -> Mesh {
        let halfX = width / 2, halfY = height / 2, halfZ = depth / 2
        var builder = MeshBuilder()
        for axis in 0..<Self.axisCount {
            for side in [-1.0, 1.0] {
                var outward = Vector3.zero
                var corners: [Vector3] = []
                switch axis {
                case 0:
                    outward = Vector3(side, 0, 0)
                    corners = [Vector3(side * halfX, -halfY, -halfZ), Vector3(side * halfX, halfY, -halfZ),
                               Vector3(side * halfX, halfY, halfZ), Vector3(side * halfX, -halfY, halfZ)]
                case 1:
                    outward = Vector3(0, side, 0)
                    corners = [Vector3(-halfX, side * halfY, -halfZ), Vector3(halfX, side * halfY, -halfZ),
                               Vector3(halfX, side * halfY, halfZ), Vector3(-halfX, side * halfY, halfZ)]
                default:
                    outward = Vector3(0, 0, side)
                    corners = [Vector3(-halfX, -halfY, side * halfZ), Vector3(halfX, -halfY, side * halfZ),
                               Vector3(halfX, halfY, side * halfZ), Vector3(-halfX, halfY, side * halfZ)]
                }
                builder.addQuad(corners, facing: outward, material: material)
            }
        }
        return builder.mesh
    }

    /// A cube with sides of `size`.
    public static func cube(size: Double = 1, material: Int = 0) -> Mesh {
        box(width: size, height: size, depth: size, material: material)
    }

    /// A sphere of `radius`, cut into `segments` around and `rings` from
    /// pole to pole.
    public static func sphere(radius: Double = 1, segments: Int = 32, rings: Int = 16, material: Int = 0) -> Mesh {
        let around = max(Self.minimumSegments, segments), down = max(2, rings)
        var builder = MeshBuilder()
        for ring in 0...down {
            let polar = Double.pi * Double(ring) / Double(down)
            for segment in 0...around {
                let azimuth = 2 * Double.pi * Double(segment) / Double(around)
                let normal = Vector3(sin(polar) * cos(azimuth), cos(polar), sin(polar) * sin(azimuth))
                builder.positions.append(normal * radius)
                builder.normals.append(normal)
                builder.tints.append(0)
            }
        }
        let stride = around + 1
        for ring in 0..<down {
            for segment in 0..<around {
                let corner = ring * stride + segment
                builder.addSmoothTriangle(corner, corner + stride, corner + stride + 1, material: material)
                builder.addSmoothTriangle(corner, corner + stride + 1, corner + 1, material: material)
            }
        }
        return builder.mesh
    }

    /// A ring lying in the x–z plane: a tube of `minorRadius` swept round a
    /// circle of `majorRadius`, cut into `majorSegments` round the ring and
    /// `minorSegments` round the tube.
    public static func torus(majorRadius: Double = 1, minorRadius: Double = 0.4,
                             majorSegments: Int = 48, minorSegments: Int = 24, material: Int = 0) -> Mesh {
        let around = max(Self.minimumSegments, majorSegments), tube = max(Self.minimumSegments, minorSegments)
        var builder = MeshBuilder()
        for major in 0...around {
            let ringAngle = 2 * Double.pi * Double(major) / Double(around)
            for minor in 0...tube {
                let tubeAngle = 2 * Double.pi * Double(minor) / Double(tube)
                let normal = Vector3(cos(tubeAngle) * cos(ringAngle), sin(tubeAngle), cos(tubeAngle) * sin(ringAngle))
                let centre = Vector3(cos(ringAngle), 0, sin(ringAngle)) * majorRadius
                builder.positions.append(centre + normal * minorRadius)
                builder.normals.append(normal)
                builder.tints.append(0)
            }
        }
        let stride = tube + 1
        for major in 0..<around {
            for minor in 0..<tube {
                let corner = major * stride + minor
                builder.addSmoothTriangle(corner, corner + stride, corner + stride + 1, material: material)
                builder.addSmoothTriangle(corner, corner + stride + 1, corner + 1, material: material)
            }
        }
        return builder.mesh
    }

    /// An upright cylinder of `radius` and `height`, its side cut into
    /// `segments` and shaded smooth, with flat caps. The side is drawn in
    /// `material` and the caps in `capMaterial`, or in `material` too when
    /// it is nil.
    public static func cylinder(radius: Double = 1, height: Double = 1, segments: Int = 32,
                                material: Int = 0, capMaterial: Int? = nil) -> Mesh {
        upright(sides: segments, radius: radius, height: height, smooth: true,
                material: material, capMaterial: capMaterial ?? material)
    }

    /// An upright prism with `sides` flat sides — six for a hexagonal
    /// column — round a circle of `radius`, `height` tall, its sides in
    /// `material` and its caps in `capMaterial`, or in `material` too when
    /// it is nil.
    public static func prism(sides: Int, radius: Double = 1, height: Double = 1,
                             material: Int = 0, capMaterial: Int? = nil) -> Mesh {
        upright(sides: sides, radius: radius, height: height, smooth: false,
                material: material, capMaterial: capMaterial ?? material)
    }

    private static func upright(sides: Int, radius: Double, height: Double, smooth: Bool,
                                material: Int, capMaterial: Int) -> Mesh {
        let count = max(Self.minimumSegments, sides)
        let halfHeight = height / 2
        let rim = (0..<count).map { index -> Vector3 in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return Vector3(cos(angle) * radius, 0, sin(angle) * radius)
        }
        var builder = MeshBuilder()
        if smooth {
            for index in 0...count {
                let point = rim[index % count]
                let normal = point.normalized
                for level in [-halfHeight, halfHeight] {
                    builder.positions.append(point + Vector3(0, level, 0))
                    builder.normals.append(normal)
                    builder.tints.append(0)
                }
            }
            for index in 0..<count {
                let corner = index * 2
                builder.addSmoothTriangle(corner, corner + 1, corner + 3, material: material)
                builder.addSmoothTriangle(corner, corner + 3, corner + 2, material: material)
            }
        } else {
            for index in 0..<count {
                let from = rim[index], to = rim[(index + 1) % count]
                let outward = ((from + to) / 2).normalized
                builder.addQuad([from + Vector3(0, -halfHeight, 0), to + Vector3(0, -halfHeight, 0),
                                 to + Vector3(0, halfHeight, 0), from + Vector3(0, halfHeight, 0)],
                                facing: outward, material: material)
            }
        }
        for (level, outward) in [(halfHeight, Vector3.unitY), (-halfHeight, -Vector3.unitY)] {
            let centre = Vector3(0, level, 0)
            for index in 0..<count {
                let from = rim[index] + centre, to = rim[(index + 1) % count] + centre
                let normal = (to - centre).cross(from - centre)
                if normal.dot(outward) >= 0 {
                    builder.addTriangle(centre, to, from, material: capMaterial)
                } else {
                    builder.addTriangle(centre, from, to, material: capMaterial)
                }
            }
        }
        return builder.mesh
    }

    /// The axes a box has a pair of faces across.
    private static let axisCount = 3
    /// The fewest segments a round solid is cut into: a triangle's worth.
    static let minimumSegments = 3
}
