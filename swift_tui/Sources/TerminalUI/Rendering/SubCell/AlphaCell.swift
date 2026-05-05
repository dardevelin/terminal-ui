// HYP-298 — alpha-aware cell + 2D buffer. Mirrors `Cell` and
// `CellBuffer` but adds an alpha channel for compositing into an
// existing CellBuffer with proper RGB blending.

/// Integer point in cell-grid coordinates. Used by
/// `Compositor.compositeAlphaLayer` to place a layer at an offset
/// inside the destination CellBuffer.
public struct Point: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int

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
    public var glyph: SubCellGlyph
    public var foreground: Color
    public var background: Color
    public var alpha: Double

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
    public let width: Int
    public let height: Int
    public var cells: [AlphaCell]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.cells = Array(repeating: .empty, count: width * height)
    }

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
