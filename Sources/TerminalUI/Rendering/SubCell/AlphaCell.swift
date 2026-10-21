// Alpha-aware cell + 2D buffer. Mirrors `Cell` and
// `CellBuffer` but adds an alpha channel for compositing into an
// existing CellBuffer with proper RGB blending.

/// Integer point in cell-grid coordinates. Used by
/// `Compositor.compositeAlphaLayer` to place a layer at an offset
/// inside the destination CellBuffer.
public struct Point: Sendable, Equatable, Hashable {
    /// Column, 0-based from the left edge.
    public var x: Int
    /// Row, 0-based from the top edge.
    public var y: Int

    /// Creates a point at cell coordinates (`x`, `y`).
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

//
// AlphaLayer is the input to `Compositor.compositeAlphaLayer`. When
// alpha == 1.0 the cell is opaque and overwrites; alpha == 0.0
// preserves the destination; values between blend RGB foreground
// and background.

/// A cell carrying a SubCellGlyph + foreground/background colors +
/// alpha. The compositor blends this against an existing CellBuffer
/// cell to produce the rendered output.
public struct AlphaCell: Sendable, Equatable {
    /// The sub-cell shape drawn in this cell.
    public var glyph: SubCellGlyph
    /// Color of the glyph's lit sub-pixels.
    public var foreground: Color
    /// Color behind the glyph's unlit sub-pixels.
    public var background: Color
    /// Opacity in `0...1`: 1 overwrites the destination cell, 0 preserves
    /// it, in-between values RGB-blend.
    public var alpha: Double

    /// Creates a compositable cell.
    public init(glyph: SubCellGlyph, foreground: Color, background: Color, alpha: Double) {
        self.glyph = glyph
        self.foreground = foreground
        self.background = background
        self.alpha = alpha
    }

    /// Default-empty cell — transparent space, used when initialising
    /// an AlphaLayer.
    public static let empty = AlphaCell(
        glyph: .full,
        foreground: .rgb(0, 0, 0),
        background: .rgb(0, 0, 0),
        alpha: 0.0
    )
}

/// 2D buffer of AlphaCells, mirroring `CellBuffer`'s shape. Used as
/// the input to `Compositor.compositeAlphaLayer`.
public struct AlphaLayer: Sendable {
    /// Layer width in cells.
    public let width: Int
    /// Layer height in cells.
    public let height: Int
    /// Row-major cell storage, `cells[y * width + x]`. Prefer the bounds-
    /// checked subscript.
    public var cells: [AlphaCell]

    /// Creates a layer of `width` x `height` cells, all
    /// ``AlphaCell/empty`` (fully transparent).
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.cells = Array(repeating: .empty, count: width * height)
    }

    /// Bounds-checked cell access: out-of-range reads return
    /// ``AlphaCell/empty``, out-of-range writes are ignored.
    public subscript(x: Int, y: Int) -> AlphaCell {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return .empty }
            return cells[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            cells[y * width + x] = newValue
        }
    }
}
