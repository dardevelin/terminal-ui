/// Renders a short string as large dot-matrix display characters —
/// airport-departure-board / LED-marquee lettering.
///
/// Each character comes from the shared 5x7 ``DotFont`` and scales up to
/// display size in one of three ways: `.bullet` (the default) spends one
/// terminal cell per dot (`●`), giving big 7-row letters; `.halfBlock`
/// packs two dot rows into each cell with `▀ ▄ █`, giving solid 4-row
/// letters — the wordmark style of agent TUIs such as Crush; `.braille`
/// packs the dots 2x4 into braille glyphs, giving compact 2-row letters.
/// Glyph geometry is fixed — the view opts out of wrapping, so give it room
/// or it clips. This is a display element for banners and splash headers;
/// for ordinary text use ``Text``, and for a scrolling animated strip see
/// ``MorseTicker``.
///
/// ```swift
/// DotMatrixText("HELLO", mode: .braille)
///     .foreground(.cyan)
///
/// DotMatrixText("CODER", mode: .halfBlock)
///     .gradient(from: theme.secondary, to: theme.primary)
/// ```
public struct DotMatrixText: TerminalView {
    /// The string to render; characters outside ``DotFont``'s ASCII
    /// coverage fall back to the `?` glyph.
    public let text: String
    /// Bullet (large), half-block (solid) or braille (compact) rendering.
    public let mode: RenderMode
    /// Dot columns of blank space between letters.
    public let letterGap: Int
    /// The colours swept across the columns, set by ``gradient(through:)``.
    private var stops: [Color] = []

    /// How dots become terminal glyphs.
    public enum RenderMode: Sendable {
        /// Compact braille rendering — 2x4 dots per terminal cell
        case braille
        /// Bullet character rendering — one dot per cell, customizable characters
        case bullet(dot: String, empty: String)
        /// Half-block rendering — one dot column per cell, two dot rows per
        /// cell, drawn with the upper, lower and full blocks
        case halfBlock

        /// `.bullet` with `●` dots and space gaps.
        public static let `default`: RenderMode = .bullet(dot: "\u{25CF}", empty: " ")
    }

    /// Creates a dot-matrix text display.
    ///
    /// - Parameters:
    ///   - text: String to render in dot-matrix glyphs.
    ///   - mode: Rendering mode (default `.bullet` with `●`).
    ///   - letterGap: Blank dot columns between letters (default 1).
    public init(_ text: String, mode: RenderMode = .default, letterGap: Int = 1) {
        self.text = text
        self.mode = mode
        self.letterGap = letterGap
    }

    /// The letters with a colour ramp swept across them, left to right, one
    /// step per terminal column, so each column is one colour from top to
    /// bottom.
    ///
    /// Blending happens in Oklab, as ``Text/gradient(_:from:to:)``'s does.
    public func gradient(from start: Color, to end: Color) -> DotMatrixText {
        gradient(through: [start, end])
    }

    /// The letters swept through every stop in order, one step per terminal
    /// column. One stop paints them in a single colour, and an empty list
    /// leaves them to the surrounding foreground.
    public func gradient(through stops: [Color]) -> DotMatrixText {
        var copy = self
        copy.stops = stops
        return copy
    }

    /// The columns the letters span: one per dot column in bullet and
    /// half-block modes, one per braille cell — what to size a rule or a
    /// caption by to line up with them.
    public var columns: Int {
        cells(of: dots()).first?.count ?? 0
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        // `.wrap(.none)` — dot-matrix glyphs are fixed geometry. Without
        // this the measurer would inflate height when the container is
        // narrower than the glyph row width, starving Spacer siblings and
        // collapsing the visible output to one row.
        styled(cells(of: dots())).wrap(.none)
    }

    // MARK: - Dots

    /// The lit dots of the whole string, one row per font row, letters
    /// side by side with `letterGap` blank columns between them. Every row
    /// is as long as the others.
    private func dots() -> [[Bool]] {
        var matrix = Array(repeating: [Bool](), count: DotFont.glyphHeight)
        for (index, character) in text.enumerated() {
            let glyph = DotFont.glyph(for: character)
            for row in 0..<DotFont.glyphHeight {
                if index > 0 {
                    matrix[row].append(contentsOf: repeatElement(false, count: letterGap))
                }
                matrix[row].append(contentsOf: glyph[row].map { $0 == "#" })
            }
        }
        return matrix
    }

    // MARK: - Cells

    /// The glyph in each terminal cell, row by row.
    private func cells(of dots: [[Bool]]) -> [[String]] {
        switch mode {
        case .bullet(let dot, let empty):
            dots.map { row in row.map { $0 ? dot : empty } }
        case .halfBlock:
            HalfBlock.cells(of: dots)
        case .braille:
            Braille.cells(of: dots)
        }
    }

    private func styled(_ cells: [[String]]) -> Text {
        guard !stops.isEmpty else {
            return Text(cells.map { $0.joined() }.joined(separator: "\n"))
        }
        let ramp = Color.ramp(through: stops, count: cells.first?.count ?? 0)
        var spans: [TextSpan] = []
        for (index, row) in cells.enumerated() {
            if index > 0 { spans.append(TextSpan("\n")) }
            spans += zip(row, ramp).map { TextSpan($0, foreground: $1) }
        }
        return Text(spans: spans)
    }
}

/// Two dot rows to a cell, as half-block image renderers pack pixels: the
/// upper dot lights the cell's top quadrants, the lower its bottom ones.
private enum HalfBlock {
    static func cells(of dots: [[Bool]]) -> [[String]] {
        stride(from: 0, to: dots.count, by: 2).map { top in
            dots[top].indices.map { column in
                var mask: QuadrantMask = dots[top][column] ? [.topLeft, .topRight] : []
                if top + 1 < dots.count, dots[top + 1][column] {
                    mask.formUnion([.bottomLeft, .bottomRight])
                }
                return String(mask.character)
            }
        }
    }
}

/// A 2x4 dot grid to a cell, Unicode's braille patterns.
private enum Braille {
    /// The dot at each row and column of the cell: dots 1–3 and 4–6 run
    /// down the columns, 7 and 8 sit beneath them.
    static let dots: [[BrailleDots]] = [
        [.dot1, .dot4],
        [.dot2, .dot5],
        [.dot3, .dot6],
        [.dot7, .dot8],
    ]
    static let cellHeight = dots.count
    static let cellWidth = dots[0].count

    static func cells(of lit: [[Bool]]) -> [[String]] {
        let width = lit.first?.count ?? 0
        return stride(from: 0, to: lit.count, by: cellHeight).map { top in
            stride(from: 0, to: width, by: cellWidth).map { left in
                var pattern: BrailleDots = []
                for row in 0..<cellHeight where top + row < lit.count {
                    for column in 0..<cellWidth where left + column < width && lit[top + row][left + column] {
                        pattern.insert(dots[row][column])
                    }
                }
                return String(pattern.character)
            }
        }
    }
}
