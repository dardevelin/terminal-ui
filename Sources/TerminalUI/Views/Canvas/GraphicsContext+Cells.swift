/// One cell of the text plane, as ``GraphicsContext/drawCells(columns:rows:at:cell:)``
/// draws it: a character and its colours.
public struct CanvasCell: Equatable, Sendable {
    /// What the cell shows. A double-width character is skipped: a block of
    /// cells gives each cell one column.
    public var character: Character
    /// The character's colour; nil takes the canvas's foreground.
    public var foreground: Color?
    /// The cell's background; nil keeps the fill beneath it.
    public var background: Color?
    /// Whether the character is bold.
    public var bold: Bool

    /// A cell showing `character` in `foreground` over `background`.
    public init(_ character: Character, foreground: Color? = nil, background: Color? = nil, bold: Bool = false) {
        self.character = character
        self.foreground = foreground
        self.background = background
        self.bold = bold
    }
}

// Block transfers: a picture the caller has worked out sample by sample —
// a software renderer's frame, an image — drawn into the planes without a
// path or a `Text` per sample. The caller is asked for each sample in turn
// and nothing is built for it, so a frame of tens of thousands of samples
// allocates nothing once the canvas's palette has seen its colours.
extension GraphicsContext {
    /// Fill a block of half cells, `columns` across and `halfRows` down,
    /// with the colour `colour` gives each — nil leaves one as it was.
    ///
    /// The block's top-left half cell is the one nearest `origin`, in the
    /// context's coordinates; the context's scale does not apply, since a
    /// block is one colour per half cell. Its clip and opacity do, as for a
    /// fill.
    ///
    /// ```swift
    /// context.fillHalfCells(columns: picture.width, halfRows: picture.height) { column, halfRow in
    ///     picture.colour(x: column, y: halfRow)
    /// }
    /// ```
    public func fillHalfCells(columns: Int, halfRows: Int, at origin: CanvasPoint = .zero,
                              colour: (_ column: Int, _ halfRow: Int) -> Color?) {
        let opacity = min(1, max(0, self.opacity))
        guard opacity > 0, columns > 0, halfRows > 0, raster.width > 0, raster.height > 0 else { return }
        let placed = transform.applied(to: origin)
        guard placed.x.isFinite, placed.y.isFinite else { return }
        let left = Int(placed.x.rounded())
        let top = Int((placed.y * Double(CanvasGrid.halfBlockRows)).rounded())
        let gridHeight = raster.height * CanvasGrid.halfBlockRows
        let firstRow = max(0, top), lastRow = min(gridHeight, top + halfRows)
        let firstColumn = max(0, left), lastColumn = min(raster.width, left + columns)
        guard firstRow < lastRow, firstColumn < lastColumn else { return }
        let mask = clipMask?.halfBlock
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn {
                guard let shade = colour(column - left, row - top) else { continue }
                let ink = raster.inkIndex(CanvasInk(colour: shade, opacity: 1))
                raster.paintGround(row: row, start: column, end: column + 1, ink: ink, opacity: opacity, mask: mask)
            }
        }
    }

    /// Draw a block of cells, `columns` across and `rows` down, over fills
    /// and strokes, each the ``CanvasCell`` `cell` gives it — nil leaves one
    /// as it was.
    ///
    /// The block's top-left cell is the one nearest `origin`, in the
    /// context's coordinates; its clip and opacity apply, as for text.
    ///
    /// ```swift
    /// let ramp = Array(" .:-=+*#%@")
    /// context.drawCells(columns: width, rows: height) { column, row in
    ///     let level = brightness(column, row)
    ///     return CanvasCell(ramp[Int(level * 9)], foreground: theme.accent)
    /// }
    /// ```
    public func drawCells(columns: Int, rows: Int, at origin: CanvasPoint = .zero,
                          cell: (_ column: Int, _ row: Int) -> CanvasCell?) {
        let opacity = min(1, max(0, self.opacity))
        guard opacity > 0, columns > 0, rows > 0, raster.width > 0, raster.height > 0 else { return }
        let placed = transform.applied(to: origin)
        guard placed.x.isFinite, placed.y.isFinite else { return }
        let left = Int(placed.x.rounded()), top = Int(placed.y.rounded())
        let firstRow = max(0, top), lastRow = min(raster.height, top + rows)
        let firstColumn = max(0, left), lastColumn = min(raster.width, left + columns)
        guard firstRow < lastRow, firstColumn < lastColumn else { return }
        let mask = clipMask?.cell
        let width = raster.width
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn {
                if let mask, !mask[row * width + column] { continue }
                guard let drawn = cell(column - left, row - top),
                      !drawn.character.isTerminalControl,
                      drawn.character.displayWidth == 1 else { continue }
                raster.placeGlyph(CanvasGlyph(
                    character: drawn.character, foreground: drawn.foreground, background: drawn.background,
                    bold: drawn.bold, italic: false, underline: false,
                    opacity: opacity, isContinuation: false),
                    x: column, y: row, columns: 1)
            }
        }
    }
}
