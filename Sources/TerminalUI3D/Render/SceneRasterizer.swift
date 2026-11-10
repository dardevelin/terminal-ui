import Foundation

/// A vertex in clip space, carrying what the samples it covers interpolate.
struct ClipVertex {
    var position: Vector4
    /// The normal in view space.
    var normal: Vector3
    var tint: Double
    /// Distance in front of the camera, along its view.
    var depth: Double

    @inline(__always)
    func interpolated(to other: ClipVertex, amount: Double) -> ClipVertex {
        ClipVertex(position: position + (other.position - position) * amount,
                   normal: normal + (other.normal - normal) * amount,
                   tint: tint + (other.tint - tint) * amount,
                   depth: depth + (other.depth - depth) * amount)
    }
}

/// Triangles into samples: the first half of a frame. Each sample keeps the
/// depth, normal, tint and material of the nearest surface covering its
/// centre; what that looks like is worked out after, once per sample, by
/// ``SceneRenderer``.
///
/// OpenGL's pipeline (Segal & Akeley, *The OpenGL Graphics System*, 4.6,
/// §§12–14): vertices to clip space, triangles cut at the near plane in it
/// (Sutherland & Hodgman, "Reentrant Polygon Clipping", CACM 17(1), 1974),
/// divided by w, culled by their winding on the screen, and covered by edge
/// functions (Pineda, "A Parallel Algorithm for Polygon Rasterization",
/// SIGGRAPH 1988). Attributes are interpolated perspective-correct: each
/// over w is linear across the screen, as 1/w is, and their ratio is the
/// value (Heckbert & Moreton, "Interpolation for Polygon Texture Mapping
/// and Shading", 1991).
final class SceneRasterizer {
    /// What a sample no surface covers holds as its material.
    static let uncovered = UInt16.max

    private(set) var width = 0
    private(set) var height = 0

    let depth = SampleBuffer<Float>(0)
    let normalX = SampleBuffer<Float>(0)
    let normalY = SampleBuffer<Float>(0)
    let normalZ = SampleBuffer<Float>(0)
    let tint = SampleBuffer<Float>(0)
    let material = SampleBuffer<UInt16>(0)

    // Per-vertex scratch, kept between frames.
    private var vertices: [ClipVertex] = []
    private var polygon: [ClipVertex] = []
    private var clipped: [ClipVertex] = []

    /// Ready a frame of `width` × `height` samples, covered by nothing.
    /// Every sample starts at the camera's `far` distance, so the depth test
    /// cuts away what lies beyond it, a sample at a time.
    func begin(width: Int, height: Int, far: Double) {
        self.width = width
        self.height = height
        let count = width * height
        depth.reset(count: count, to: far > 0 ? Float(far) : .infinity)
        normalX.reset(count: count, to: 0)
        normalY.reset(count: count, to: 0)
        normalZ.reset(count: count, to: 0)
        tint.reset(count: count, to: 0)
        material.reset(count: count, to: Self.uncovered)
    }

    /// Cover the samples `model`'s front-facing triangles reach, nearer
    /// than what covers them already.
    ///
    /// - Parameters:
    ///   - modelView: The model's transform followed by the camera's view.
    ///   - projection: The camera's projection.
    ///   - materials: Where the model's materials lie in the frame's list of
    ///     them; never empty.
    ///   - doubleSided: For each of the frame's materials, whether its
    ///     triangles are drawn from behind.
    func draw(_ model: Model3D, modelView: Matrix4, projection: Matrix4, materials: Range<Int>,
              doubleSided: [Bool]) {
        let mesh = model.mesh
        guard !mesh.triangles.isEmpty, width > 0, height > 0, !materials.isEmpty,
              materials.upperBound <= doubleSided.count, materials.upperBound <= Int(Self.uncovered) else { return }
        let normalTransform = modelView.normalMatrix
        let hasNormals = mesh.normals.count == mesh.positions.count
        let hasTints = mesh.tints.count == mesh.positions.count
        vertices.removeAll(keepingCapacity: true)
        vertices.reserveCapacity(mesh.positions.count)
        for index in mesh.positions.indices {
            let viewPosition = modelView * Vector4(mesh.positions[index], 1)
            let normal = hasNormals ? normalTransform.transformDirection(mesh.normals[index]).normalized : .zero
            vertices.append(ClipVertex(position: projection * viewPosition, normal: normal,
                                       tint: hasTints ? mesh.tints[index] : 0, depth: -viewPosition.z))
        }
        for triangle in mesh.triangles {
            guard vertices.indices.contains(triangle.first), vertices.indices.contains(triangle.second),
                  vertices.indices.contains(triangle.third) else { continue }
            // A triangle naming a material past the model's last takes the last.
            let material = materials.lowerBound + min(max(0, triangle.material), materials.count - 1)
            drawTriangle(vertices[triangle.first], vertices[triangle.second], vertices[triangle.third],
                         material: UInt16(material), doubleSided: doubleSided[material])
        }
    }

    private func drawTriangle(_ first: ClipVertex, _ second: ClipVertex, _ third: ClipVertex,
                              material: UInt16, doubleSided: Bool) {
        let corner0 = first.position, corner1 = second.position, corner2 = third.position
        // Wholly outside one side of the view volume: nothing to cut.
        if (corner0.x < -corner0.w && corner1.x < -corner1.w && corner2.x < -corner2.w)
            || (corner0.x > corner0.w && corner1.x > corner1.w && corner2.x > corner2.w)
            || (corner0.y < -corner0.w && corner1.y < -corner1.w && corner2.y < -corner2.w)
            || (corner0.y > corner0.w && corner1.y > corner1.w && corner2.y > corner2.w)
            || (corner0.z > corner0.w && corner1.z > corner1.w && corner2.z > corner2.w) {
            return
        }
        // The near plane in clip space is z = −w: in front of it, z + w ≥ 0.
        let distance0 = corner0.z + corner0.w, distance1 = corner1.z + corner1.w
        let distance2 = corner2.z + corner2.w
        if distance0 >= 0 && distance1 >= 0 && distance2 >= 0 {
            rasterize(first, second, third, material: material, doubleSided: doubleSided)
            return
        }
        if distance0 < 0 && distance1 < 0 && distance2 < 0 { return }
        polygon.removeAll(keepingCapacity: true)
        polygon.append(first)
        polygon.append(second)
        polygon.append(third)
        clipped.removeAll(keepingCapacity: true)
        for index in 0..<polygon.count {
            let current = polygon[index], next = polygon[(index + 1) % polygon.count]
            let currentDistance = current.position.z + current.position.w
            let nextDistance = next.position.z + next.position.w
            if currentDistance >= 0 { clipped.append(current) }
            if (currentDistance >= 0) != (nextDistance >= 0) {
                let amount = currentDistance / (currentDistance - nextDistance)
                clipped.append(current.interpolated(to: next, amount: amount))
            }
        }
        guard clipped.count >= 3 else { return }
        for index in 1..<(clipped.count - 1) {
            rasterize(clipped[0], clipped[index], clipped[index + 1], material: material, doubleSided: doubleSided)
        }
    }

    private func rasterize(_ first: ClipVertex, _ second: ClipVertex, _ third: ClipVertex,
                           material: UInt16, doubleSided: Bool) {
        let width = self.width, height = self.height
        let halfWidth = Double(width) / 2, halfHeight = Double(height) / 2
        let inverseW0 = 1 / first.position.w, inverseW1 = 1 / second.position.w, inverseW2 = 1 / third.position.w
        guard inverseW0.isFinite, inverseW1.isFinite, inverseW2.isFinite else { return }
        // Normalised device coordinates to samples, y down the screen.
        let x0 = (first.position.x * inverseW0 + 1) * halfWidth, y0 = (1 - first.position.y * inverseW0) * halfHeight
        let x1 = (second.position.x * inverseW1 + 1) * halfWidth, y1 = (1 - second.position.y * inverseW1) * halfHeight
        let x2 = (third.position.x * inverseW2 + 1) * halfWidth, y2 = (1 - third.position.y * inverseW2) * halfHeight
        let area = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)
        guard area != 0, area.isFinite else { return }
        // Anticlockwise in the scene is clockwise once y points down the
        // screen: a front face has negative area here.
        let isBack = area > 0
        if isBack && !doubleSided { return }
        let facing: Double = isBack ? -1 : 1

        let minimumX = max(0, Int(min(x0, x1, x2).rounded(.down)))
        let maximumX = min(width - 1, Int(max(x0, x1, x2).rounded(.up)))
        let minimumY = max(0, Int(min(y0, y1, y2).rounded(.down)))
        let maximumY = min(height - 1, Int(max(y0, y1, y2).rounded(.up)))
        guard minimumX <= maximumX, minimumY <= maximumY else { return }

        let inverseArea = 1 / area
        // Each edge function, and its step one sample right.
        let step0 = -(y2 - y1) * inverseArea, step1 = -(y0 - y2) * inverseArea, step2 = -(y1 - y0) * inverseArea
        let depthOverW0 = first.depth * inverseW0, depthOverW1 = second.depth * inverseW1
        let depthOverW2 = third.depth * inverseW2

        let depthPointer = depth.pointer, materialPointer = self.material.pointer
        let normalXPointer = normalX.pointer, normalYPointer = normalY.pointer, normalZPointer = normalZ.pointer
        let tintPointer = tint.pointer

        for row in minimumY...maximumY {
            let centreY = Double(row) + 0.5
            let startX = Double(minimumX) + 0.5
            var weight0 = ((x2 - x1) * (centreY - y1) - (y2 - y1) * (startX - x1)) * inverseArea
            var weight1 = ((x0 - x2) * (centreY - y2) - (y0 - y2) * (startX - x2)) * inverseArea
            var weight2 = ((x1 - x0) * (centreY - y0) - (y1 - y0) * (startX - x0)) * inverseArea
            let rowBase = row * width
            for column in minimumX...maximumX {
                defer {
                    weight0 += step0
                    weight1 += step1
                    weight2 += step2
                }
                guard weight0 >= 0, weight1 >= 0, weight2 >= 0 else { continue }
                let perspective0 = weight0 * inverseW0, perspective1 = weight1 * inverseW1
                let perspective2 = weight2 * inverseW2
                let sum = perspective0 + perspective1 + perspective2
                guard sum > 0 else { continue }
                let reciprocal = 1 / sum
                let sampleDepth = Float((weight0 * depthOverW0 + weight1 * depthOverW1 + weight2 * depthOverW2)
                                        * reciprocal)
                let index = rowBase + column
                guard sampleDepth < depthPointer[index], sampleDepth > 0 else { continue }
                depthPointer[index] = sampleDepth
                materialPointer[index] = material
                let share0 = perspective0 * reciprocal, share1 = perspective1 * reciprocal
                let share2 = perspective2 * reciprocal
                normalXPointer[index] = Float((first.normal.x * share0 + second.normal.x * share1
                                               + third.normal.x * share2) * facing)
                normalYPointer[index] = Float((first.normal.y * share0 + second.normal.y * share1
                                               + third.normal.y * share2) * facing)
                normalZPointer[index] = Float((first.normal.z * share0 + second.normal.z * share1
                                               + third.normal.z * share2) * facing)
                tintPointer[index] = Float(first.tint * share0 + second.tint * share1 + third.tint * share2)
            }
        }
    }
}
