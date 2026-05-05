// HYP-298 — alpha pattern → SubCellGlyph + AlphaCell. Used by
// shape-clip modifiers (Avatar circle clip etc.) to convert per-
// sub-pixel alpha masks into a single rendered cell.
//
// AlphaPattern is a 2-column × 4-row grid of doubles in [0, 1].
// 2×4 matches the braille-dot convention so the same fixture is
// reused for braille rendering when finest precision is wanted.
//
// SubCellRenderer maps the pattern to the closest of a small atlas:
// uniform full → .full, uniform 0 → transparent, top half opaque →
// .halfTop, etc. Quadrants and shades cover patterns that don't
// fit a half/full case. Braille is reserved for fine-grain inputs.

/// 2×4 alpha values per cell. Indexing matches braille's 2-column
/// 4-row dot grid: `pattern[col, row]` where col ∈ 0..1, row ∈ 0..3.
public struct AlphaPattern: Sendable, Equatable {
    /// Row-major 8-element array. `value[row * columns + col]`.
    public var values: [Double]

    public static let columns = 2
    public static let rows = 4

    public init(uniformValue: Double) {
        let count = AlphaPattern.columns * AlphaPattern.rows
        self.values = Array(repeating: uniformValue, count: count)
    }

    public subscript(x: Int, y: Int) -> Double {
        get {
            guard x >= 0, x < AlphaPattern.columns, y >= 0, y < AlphaPattern.rows else { return 0.0 }
            return values[y * AlphaPattern.columns + x]
        }
        set {
            guard x >= 0, x < AlphaPattern.columns, y >= 0, y < AlphaPattern.rows else { return }
            values[y * AlphaPattern.columns + x] = newValue
        }
    }

    /// Average alpha across all sub-pixels — used to detect uniform
    /// shade levels.
    var averageAlpha: Double {
        let total = values.reduce(0.0, +)
        return total / Double(values.count)
    }

    /// Are all sub-pixels at full opacity?
    var isUniformOpaque: Bool {
        return values.allSatisfy { $0 >= 0.99 }
    }

    /// Are all sub-pixels fully transparent?
    var isUniformTransparent: Bool {
        return values.allSatisfy { $0 <= 0.01 }
    }
}

/// Maps an `AlphaPattern` to the best-fitting `SubCellGlyph`.
public enum SubCellRenderer {

    /// Produce an AlphaCell for the given pattern + colors.
    /// The renderer picks the closest atlas glyph; outputs a fully
    /// transparent cell (alpha=0) when the pattern is empty.
    public static func render(
        _ pattern: AlphaPattern,
        foreground: Color,
        background: Color
    ) -> AlphaCell {
        // Fully transparent — signal via alpha=0; glyph choice doesn't
        // matter but keep it stable for diff-friendliness.
        if pattern.isUniformTransparent {
            return AlphaCell(glyph: .full, foreground: foreground, background: background, alpha: 0.0)
        }

        // Fully opaque — full block.
        if pattern.isUniformOpaque {
            return AlphaCell(glyph: .full, foreground: foreground, background: background, alpha: 1.0)
        }

        // Try to fit half-cell shapes first (they're the highest-fidelity
        // representations when the geometry happens to match).
        if let half = halfCellGlyph(for: pattern) {
            return AlphaCell(glyph: half, foreground: foreground, background: background, alpha: 1.0)
        }

        // Try quadrant fit — collapse the 2×4 pattern into a 2×2
        // quadrant grid and pick the canonical 16-pattern glyph.
        if let quadrant = quadrantGlyph(for: pattern) {
            return AlphaCell(glyph: quadrant, foreground: foreground, background: background, alpha: 1.0)
        }

        // Fallback: uniform partial coverage maps to a shade glyph.
        let shade = shadeForAverage(pattern.averageAlpha)
        return AlphaCell(glyph: .shade(shade), foreground: foreground, background: background, alpha: 1.0)
    }

    // MARK: - Half-cell heuristics

    private static func halfCellGlyph(for pattern: AlphaPattern) -> SubCellGlyph? {
        // Top half opaque, bottom half transparent → halfTop.
        let topOpaque = (0..<AlphaPattern.columns).allSatisfy { x in
            pattern[x, 0] >= 0.99 && pattern[x, 1] >= 0.99
        }
        let bottomTransparent = (0..<AlphaPattern.columns).allSatisfy { x in
            pattern[x, 2] <= 0.01 && pattern[x, 3] <= 0.01
        }
        if topOpaque && bottomTransparent {
            return .halfTop
        }

        // Bottom half opaque, top half transparent → halfBottom.
        let bottomOpaque = (0..<AlphaPattern.columns).allSatisfy { x in
            pattern[x, 2] >= 0.99 && pattern[x, 3] >= 0.99
        }
        let topTransparent = (0..<AlphaPattern.columns).allSatisfy { x in
            pattern[x, 0] <= 0.01 && pattern[x, 1] <= 0.01
        }
        if bottomOpaque && topTransparent {
            return .halfBottom
        }

        return nil
    }

    // MARK: - Quadrant fit

    /// Treat each 1×2 region of the 2×4 grid as one quadrant. If the
    /// region is mostly opaque (avg >= 0.5) the quadrant is set.
    private static func quadrantGlyph(for pattern: AlphaPattern) -> SubCellGlyph? {
        let topLeft = quadrantOpaque(pattern, xRange: 0..<1, yRange: 0..<2)
        let topRight = quadrantOpaque(pattern, xRange: 1..<2, yRange: 0..<2)
        let bottomLeft = quadrantOpaque(pattern, xRange: 0..<1, yRange: 2..<4)
        let bottomRight = quadrantOpaque(pattern, xRange: 1..<2, yRange: 2..<4)

        var mask: QuadrantMask = []
        if topLeft { mask.insert(.topLeft) }
        if topRight { mask.insert(.topRight) }
        if bottomLeft { mask.insert(.bottomLeft) }
        if bottomRight { mask.insert(.bottomRight) }

        // Empty mask falls through to shade; full mask was handled by
        // the uniformOpaque short-circuit.
        if mask.isEmpty || mask == .all {
            return nil
        }
        return .quadrant(mask)
    }

    private static func quadrantOpaque(_ pattern: AlphaPattern, xRange: Range<Int>, yRange: Range<Int>) -> Bool {
        var sum = 0.0
        var count = 0
        for y in yRange {
            for x in xRange {
                sum += pattern[x, y]
                count += 1
            }
        }
        let average = count > 0 ? sum / Double(count) : 0.0
        return average >= 0.5
    }

    // MARK: - Shade fit

    /// Map an average alpha value to the closest pre-defined shade
    /// level. Boundaries chosen so 0.25 → light, 0.5 → medium,
    /// 0.75 → dark.
    private static func shadeForAverage(_ average: Double) -> ShadeLevel {
        if average < 0.375 {
            return .light
        } else if average < 0.625 {
            return .medium
        } else {
            return .dark
        }
    }
}
