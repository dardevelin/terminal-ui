import Foundation

extension Mesh {
    /// A terrain: a grid of `columns` × `rows` heights, `spacing` apart in
    /// the x–z plane and centred on the origin, `heights[row * columns +
    /// column]` the height up y of each point.
    ///
    /// Each vertex's normal comes from the slope of its neighbours (central
    /// differences), so the ground shades smooth. Its tint, unless `tints`
    /// gives them, is its height from the lowest point, 0, to the highest, 1:
    /// a gradient material colours the terrain by height.
    ///
    /// ```swift
    /// let ground = Mesh.heightField(columns: 64, rows: 64, spacing: 0.5,
    ///                               heights: elevations)
    /// let terrain = Material(gradient: [theme.info, theme.success, theme.warning, theme.foreground])
    /// ```
    ///
    /// - Returns: The empty mesh when `heights` does not hold a height for
    ///   every point of a grid at least 2 × 2.
    public static func heightField(columns: Int, rows: Int, spacing: Double = 1, heights: [Double],
                                   tints: [Double]? = nil, material: Int = 0) -> Mesh {
        guard columns >= 2, rows >= 2, heights.count == columns * rows else { return .empty }
        let lowest = heights.min() ?? 0, highest = heights.max() ?? 0
        let range = highest - lowest
        let originX = -Double(columns - 1) * spacing / 2, originZ = -Double(rows - 1) * spacing / 2
        func height(_ column: Int, _ row: Int) -> Double {
            heights[min(rows - 1, max(0, row)) * columns + min(columns - 1, max(0, column))]
        }
        var builder = MeshBuilder()
        builder.positions.reserveCapacity(heights.count)
        for row in 0..<rows {
            for column in 0..<columns {
                let elevation = height(column, row)
                builder.positions.append(Vector3(originX + Double(column) * spacing, elevation,
                                                 originZ + Double(row) * spacing))
                // The surface y = h(x, z) has normal (−∂h/∂x, 1, −∂h/∂z).
                let slopeX = (height(column + 1, row) - height(column - 1, row)) / (2 * spacing)
                let slopeZ = (height(column, row + 1) - height(column, row - 1)) / (2 * spacing)
                builder.normals.append(Vector3(-slopeX, 1, -slopeZ).normalized)
                let index = row * columns + column
                if let tints, tints.indices.contains(index) {
                    builder.tints.append(tints[index])
                } else {
                    builder.tints.append(range > 0 ? (elevation - lowest) / range : 0)
                }
            }
        }
        builder.triangles.reserveCapacity((columns - 1) * (rows - 1) * 2)
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let corner = row * columns + column
                builder.addSmoothTriangle(corner, corner + columns, corner + columns + 1, material: material)
                builder.addSmoothTriangle(corner, corner + columns + 1, corner + 1, material: material)
            }
        }
        return builder.mesh
    }

    /// A terrain of `columns` × `rows` points `spacing` apart, `height`
    /// giving each point's height from its column and row.
    public static func heightField(columns: Int, rows: Int, spacing: Double = 1, material: Int = 0,
                                   height: (_ column: Int, _ row: Int) -> Double) -> Mesh {
        guard columns >= 2, rows >= 2 else { return .empty }
        var heights: [Double] = []
        heights.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns { heights.append(height(column, row)) }
        }
        return heightField(columns: columns, rows: rows, spacing: spacing, heights: heights, material: material)
    }
}
