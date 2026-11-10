// The planes a `Canvas` draws into, and how they become cells.
//
// Three planes, each at the resolution the terminal can show it at:
//
// - ground: fills, two samples per cell, the upper and lower halves that
//   U+2580 ▀ (UPPER HALF BLOCK) splits a cell into — its foreground paints
//   the upper half, its background the lower;
// - strokes: the eight dots of a Unicode braille pattern (U+2800–U+28FF),
//   two columns by four rows per cell, with one foreground colour per cell
//   because a cell has one;
// - text: whole cells, a double-width glyph as a pair.
//
// Colours are kept as indices into a palette rebuilt with each drawing, so
// the hot paths compare and store integers; the planes and every scratch
// array live as long as the canvas's graph node and keep their capacity
// between drawings. A frame that draws nothing new composites the planes the
// last drawing left.

/// What the stroke plane can draw at: how finely a ``GraphicsContext``
/// places a stroke inside each cell.
///
/// Set it for a subtree with ``TerminalView/canvasResolution(_:)``, or for
/// the strokes that follow with ``GraphicsContext/resolution``. Fills are
/// always drawn at half-block resolution, and text on whole cells.
public enum CanvasResolution: Sendable, Equatable, Hashable {
    /// Braille dots, 2 × 4 to a cell, one colour per cell: the finest a
    /// terminal draws. A later stroke of another colour clears the dots an
    /// earlier one left in the cells it reaches, so a road over a river
    /// reads as a bridge rather than a blend.
    case braille
    /// Half cells, 1 × 2 to a cell, drawn into the fill plane in the
    /// stroke's colour — solid where braille is dotted.
    case halfBlock
    /// Whole cells, drawn into the fill plane in the stroke's colour.
    case cell

    /// Sample columns per cell.
    var columnsPerCell: Int {
        switch self {
        case .braille: CanvasGrid.brailleColumns
        case .halfBlock, .cell: 1
        }
    }

    /// Sample rows per cell.
    var rowsPerCell: Int {
        switch self {
        case .braille: CanvasGrid.brailleRows
        case .halfBlock: CanvasGrid.halfBlockRows
        case .cell: 1
        }
    }
}

/// Sub-cell geometry the planes share.
enum CanvasGrid {
    /// A braille pattern's dot columns (Unicode 3.0, U+2800 block).
    static let brailleColumns = 2
    /// A braille pattern's dot rows: dots 1-2-3 and 7 down the left column.
    static let brailleRows = 4
    /// The halves U+2580 ▀ and U+2584 ▄ divide a cell into.
    static let halfBlockRows = 2
    /// The empty braille pattern, U+2800; a pattern's dots are its offset
    /// from it, dot n in bit n − 1.
    static let brailleBase: UInt32 = 0x2800
    /// The bit each dot sets, indexed `row * 2 + column` and packed a byte
    /// apiece from the low byte up: dots 1 4 / 2 5 / 3 6 / 7 8 by row,
    /// whose bits are 0x01 0x08 / 0x02 0x10 / 0x04 0x20 / 0x40 0x80.
    static let brailleBits: UInt64 = 0x8040_2004_1002_0801
    /// Bits per byte of ``brailleBits``.
    static let bitsPerByte: UInt64 = 8
    /// The upper half block, whose foreground is a cell's top half.
    static let upperHalf: Character = "\u{2580}"
    /// The lower half block, for a cell whose top half has no colour to
    /// give a foreground.
    static let lowerHalf: Character = "\u{2584}"
    /// Columns a double-width glyph covers (UAX #11 W and F).
    static let wideGlyphColumns = 2

    /// The bit dot (`column`, `row`) of a cell sets in its pattern.
    @inline(__always)
    static func brailleBit(column: Int, row: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: brailleBits >> (UInt64(row * brailleColumns + column) * bitsPerByte))
    }
}

/// A colour as drawn: the colour and the opacity it was drawn at.
struct CanvasInk: Hashable {
    var colour: Color
    var opacity: Double

    /// Hashes what `Color`'s `==` compares — how the colour is encoded —
    /// so two inks equal under it hash alike. The seventeen named colours
    /// share one hash, which `==` then tells apart: cheaper than naming
    /// each, and too few to cost a lookup anything.
    func hash(into hasher: inout Hasher) {
        switch colour {
        case .ansi256(let index):
            hasher.combine(CanvasInk.indexedTag)
            hasher.combine(index)
        case .rgb(let red, let green, let blue):
            hasher.combine(CanvasInk.rgbTag)
            hasher.combine(red)
            hasher.combine(green)
            hasher.combine(blue)
        default:
            hasher.combine(CanvasInk.namedTag)
        }
        hasher.combine(opacity)
    }

    /// Tags that keep the encodings' hashes apart.
    private static let namedTag: UInt8 = 0
    private static let indexedTag: UInt8 = 1
    private static let rgbTag: UInt8 = 2
}

/// One cell of the text plane.
struct CanvasGlyph {
    var character: Character
    /// nil inherits the canvas's foreground.
    var foreground: Color?
    /// nil keeps what lies beneath.
    var background: Color?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var opacity: Double
    /// The right half of the double-width glyph to its left.
    var isContinuation: Bool
}

/// Where the context's drawing reaches, rasterised once per resolution:
/// a cell, a half cell or a dot is drawn only where its centre is inside.
final class CanvasClipMask {
    let braille: [Bool]
    let halfBlock: [Bool]
    let cell: [Bool]

    init(braille: [Bool], halfBlock: [Bool], cell: [Bool]) {
        self.braille = braille
        self.halfBlock = halfBlock
        self.cell = cell
    }

    func mask(for resolution: CanvasResolution) -> [Bool] {
        switch resolution {
        case .braille: braille
        case .halfBlock: halfBlock
        case .cell: cell
        }
    }
}

/// A scale and then a translation — what `translateBy` and `scaleBy`
/// compose to. No rotation, so a rectangle stays one and a cell stays
/// square to the grid.
struct CanvasTransform: Equatable {
    var scaleX = 1.0
    var scaleY = 1.0
    var translateX = 0.0
    var translateY = 0.0

    @inline(__always)
    func applied(to point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(x: point.x * scaleX + translateX, y: point.y * scaleY + translateY)
    }
}

/// A path as polylines in sample units, for one resolution.
struct FlattenedPath {
    var xs: [Double] = []
    var ys: [Double] = []
    /// One past each subpath's last point.
    var ends: [Int] = []
    var closed: [Bool] = []

    /// A curve is cut into about √L chords, L its control polygon's length
    /// in samples: a chord across an arc of radius r and angle θ strays
    /// r(1 − cos(θ/2)) ≈ rθ²/8 from it, so a quarter ellipse (L ≈ 1.6r)
    /// in √L chords strays under a quarter of a sample.
    static let maximumChords = 1024

    mutating func removeAll() {
        xs.removeAll(keepingCapacity: true)
        ys.removeAll(keepingCapacity: true)
        ends.removeAll(keepingCapacity: true)
        closed.removeAll(keepingCapacity: true)
    }

    /// Replace the contents with `path` through `transform`, scaled to
    /// `columnsPerCell` × `rowsPerCell` samples per cell.
    mutating func load(_ path: Path, transform: CanvasTransform, columnsPerCell: Int, rowsPerCell: Int) {
        removeAll()
        let sampleScaleX = Double(columnsPerCell), sampleScaleY = Double(rowsPerCell)
        var subpathBegin = 0
        var start: CanvasPoint?
        var current = CanvasPoint.zero

        func place(_ point: CanvasPoint) -> CanvasPoint {
            let moved = transform.applied(to: point)
            return CanvasPoint(x: moved.x * sampleScaleX, y: moved.y * sampleScaleY)
        }
        func append(_ point: CanvasPoint) {
            xs.append(point.x)
            ys.append(point.y)
        }
        func finish(closing: Bool) {
            guard xs.count > subpathBegin else { return }
            ends.append(xs.count)
            closed.append(closing)
            subpathBegin = xs.count
        }
        // After a close, a segment with no move first starts again from the
        // closed subpath's beginning, as Core Graphics continues one.
        func ensureOpen() {
            guard xs.count == subpathBegin, let start else { return }
            append(start)
        }

        for element in path.elements {
            switch element {
            case .move(let point):
                finish(closing: false)
                let placed = place(point)
                start = placed
                current = placed
                append(placed)
            case .line(let point):
                ensureOpen()
                current = place(point)
                append(current)
            case .quadCurve(let point, let control):
                ensureOpen()
                let end = place(point), handle = place(control)
                let length = distance(current, handle) + distance(handle, end)
                let chords = Self.chords(forLength: length)
                for step in 1...chords {
                    let t = Double(step) / Double(chords), u = 1 - t
                    append(CanvasPoint(
                        x: u * u * current.x + 2 * u * t * handle.x + t * t * end.x,
                        y: u * u * current.y + 2 * u * t * handle.y + t * t * end.y))
                }
                current = end
            case .curve(let point, let control1, let control2):
                ensureOpen()
                let end = place(point), handle1 = place(control1), handle2 = place(control2)
                let length = distance(current, handle1) + distance(handle1, handle2) + distance(handle2, end)
                let chords = Self.chords(forLength: length)
                for step in 1...chords {
                    let t = Double(step) / Double(chords), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    append(CanvasPoint(
                        x: a * current.x + b * handle1.x + c * handle2.x + d * end.x,
                        y: a * current.y + b * handle1.y + c * handle2.y + d * end.y))
                }
                current = end
            case .closeSubpath:
                finish(closing: true)
                if let start { current = start }
            }
        }
        finish(closing: false)
    }

    private static func chords(forLength length: Double) -> Int {
        guard length.isFinite, length > 1 else { return 1 }
        return min(maximumChords, Int(length.squareRoot().rounded(.up)))
    }

    private func distance(_ from: CanvasPoint, _ to: CanvasPoint) -> Double {
        let deltaX = to.x - from.x, deltaY = to.y - from.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }
}

/// One edge of a polygon being filled, in sample units.
struct ScanlineEdge {
    var yTop: Double
    var xAtTop: Double
    /// Δx per unit of y.
    var slope: Double
    var lastRow: Int
    /// +1 for an edge running down, −1 for one running up.
    var winding: Int
}

/// The planes, their palette and the scratch the rasterisers reuse.
final class CanvasRaster {
    /// Posted when what the renderer read changes, so the canvas draws again.
    weak let inbox: InvalidationInbox?

    private(set) var width = 0
    private(set) var height = 0

    /// Whether the planes must be drawn again before they are composited:
    /// the canvas was handed a new renderer, what its renderer read changed,
    /// or the environment around it may have. Otherwise a frame composites
    /// what the last drawing left, and the renderer does not run.
    var needsRender = true

    /// Index 0 is "nothing drawn"; a plane stores indices into it.
    private(set) var inks: [CanvasInk] = [CanvasInk(colour: .default, opacity: 0)]
    /// Where each ink after the first sits in `inks`: a picture drawn a
    /// sample at a time brings thousands of colours, and a search of the
    /// list for each made the frame quadratic in them.
    private var inkIndices: [CanvasInk: UInt32] = [:]
    private var lastInk: (ink: CanvasInk, index: UInt32)?

    /// Two samples per cell, row-major over `height * 2` half rows.
    private(set) var ground: [UInt32] = []
    /// The dots set in each cell, as a braille pattern's bits.
    private(set) var dots: [UInt8] = []
    /// The ink of each cell's dots.
    private(set) var dotInk: [UInt32] = []
    private(set) var glyphs: [CanvasGlyph?] = []
    private var hasGlyphs = false

    /// The canvas's inherited background: what a translucent fill over
    /// nothing is mixed toward.
    private(set) var inheritedGround: Color?

    // Scratch, reused from call to call.
    var flattened = FlattenedPath()
    private var edges: [ScanlineEdge] = []
    private var bucketHeads: [Int] = []
    private var bucketNext: [Int] = []
    private var active: [Int] = []
    private var crossings: [(x: Double, winding: Int)] = []
    /// What a translucent ink makes of each ink beneath it, by the index of
    /// the one beneath, for the ink and opacity in `blendMemoKey`.
    private var blendMemo: [UInt32] = []
    private var blendMemoKey: (ink: UInt32, opacity: Double)?
    /// The samples the stroke being drawn has reached, by generation, so a
    /// translucent stroke in the fill plane mixes into each sample once
    /// however often its brush passes over it.
    private var strokeMarks: [UInt32] = []
    private var strokeGeneration: UInt32 = 0

    /// A memo slot not yet computed.
    private static let unblended = UInt32.max
    /// A sample the blend leaves as it was.
    private static let leaveAsIs = UInt32.max - 1

    init(inbox: InvalidationInbox? = nil) {
        self.inbox = inbox
    }

    /// Ready the planes for a frame of `width` × `height` cells, cleared.
    func begin(width: Int, height: Int, inheritedGround: Color?) {
        self.inheritedGround = inheritedGround
        inks.removeSubrange(1...)
        inkIndices.removeAll(keepingCapacity: true)
        lastInk = nil
        blendMemoKey = nil
        let cells = width * height
        if width != self.width || height != self.height {
            self.width = width
            self.height = height
            ground = Array(repeating: 0, count: cells * CanvasGrid.halfBlockRows)
            dots = Array(repeating: 0, count: cells)
            dotInk = Array(repeating: 0, count: cells)
            glyphs = Array(repeating: nil, count: cells)
            hasGlyphs = false
            return
        }
        ground.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        dots.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        dotInk.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        if hasGlyphs {
            for index in glyphs.indices { glyphs[index] = nil }
            hasGlyphs = false
        }
    }

    // MARK: Palette

    func inkIndex(_ ink: CanvasInk) -> UInt32 {
        if let lastInk, lastInk.ink == ink { return lastInk.index }
        let index: UInt32
        if let found = inkIndices[ink] {
            index = found
        } else {
            inks.append(ink)
            index = UInt32(inks.count - 1)
            inkIndices[ink] = index
        }
        lastInk = (ink, index)
        return index
    }

    /// `colour` at `opacity` over `ground`: mixed in Oklab where both are
    /// known colours; where the ground is the terminal's own, unknowable,
    /// the colour where it is at least half opaque and nothing where not.
    static func blend(_ colour: Color, opacity: Double, over ground: Color?) -> Color? {
        if opacity >= 1 { return colour }
        guard opacity > 0 else { return nil }
        if let ground, ground.nominalRGB != nil, colour.nominalRGB != nil {
            return ground.blended(with: colour, amount: opacity)
        }
        return opacity >= 0.5 ? colour : nil
    }

    // MARK: Ground plane

    /// Paint ground samples `start ..< end` of half row `row` with `ink`.
    func paintGround(row: Int, start: Int, end: Int, ink: UInt32, opacity: Double, mask: [Bool]?) {
        let base = row * width
        if opacity >= 1 {
            if let mask {
                for column in start..<end where mask[base + column] { ground[base + column] = ink }
            } else {
                for column in start..<end { ground[base + column] = ink }
            }
            return
        }
        if blendMemoKey?.ink != ink || blendMemoKey?.opacity != opacity {
            blendMemo.removeAll(keepingCapacity: true)
            blendMemoKey = (ink, opacity)
        }
        for column in start..<end {
            let index = base + column
            if let mask, !mask[index] { continue }
            let result = blendedGround(under: ground[index], ink: ink, opacity: opacity)
            if result != Self.leaveAsIs { ground[index] = result }
        }
    }

    /// Start a stroke whose samples are marked as they are painted, on a
    /// grid of `count` samples.
    func beginStrokeMarks(count: Int) {
        if strokeMarks.count < count {
            strokeMarks = Array(repeating: 0, count: count)
            strokeGeneration = 0
        } else if strokeGeneration == UInt32.max {
            strokeMarks.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            strokeGeneration = 0
        }
        strokeGeneration += 1
    }

    /// Whether the stroke begun by ``beginStrokeMarks(count:)`` has not yet
    /// reached sample `index`, marking it reached.
    func marksStroke(_ index: Int) -> Bool {
        if strokeMarks[index] == strokeGeneration { return false }
        strokeMarks[index] = strokeGeneration
        return true
    }

    private func blendedGround(under: UInt32, ink: UInt32, opacity: Double) -> UInt32 {
        let slot = Int(under)
        if slot < blendMemo.count, blendMemo[slot] != Self.unblended { return blendMemo[slot] }
        let groundColour = under == 0 ? inheritedGround : inks[slot].colour
        let result: UInt32
        if let mixed = Self.blend(inks[Int(ink)].colour, opacity: opacity, over: groundColour) {
            result = inkIndex(CanvasInk(colour: mixed, opacity: 1))
        } else {
            result = Self.leaveAsIs
        }
        while blendMemo.count <= slot { blendMemo.append(Self.unblended) }
        blendMemo[slot] = result
        return result
    }

    // MARK: Stroke plane

    /// Run `body` with a dot setter over the stroke plane's storage, taken
    /// once for the many dots a stroke sets. The setter puts dot (`x`, `y`)
    /// in `ink`, clearing the cell's dots first when they were another
    /// ink's; the caller has checked the bounds and the clip.
    func withDots(ink: UInt32, _ body: (_ setDot: (_ x: Int, _ y: Int) -> Void) -> Void) {
        let cellsAcross = width
        dots.withUnsafeMutableBufferPointer { patterns in
            dotInk.withUnsafeMutableBufferPointer { inks in
                body { x, y in
                    let cell = (y / CanvasGrid.brailleRows) * cellsAcross + x / CanvasGrid.brailleColumns
                    if inks[cell] != ink {
                        inks[cell] = ink
                        patterns[cell] = 0
                    }
                    patterns[cell] |= CanvasGrid.brailleBit(column: x % CanvasGrid.brailleColumns,
                                                            row: y % CanvasGrid.brailleRows)
                }
            }
        }
    }

    // MARK: Text plane

    /// Put `glyph` in cell (`x`, `y`) of the text plane, keeping every
    /// double-width glyph whole: a glyph over either half of one removes
    /// the other half, as a terminal does.
    func placeGlyph(_ glyph: CanvasGlyph, x: Int, y: Int, columns: Int) {
        let index = y * width + x
        release(index: index, x: x)
        glyphs[index] = glyph
        if columns == CanvasGrid.wideGlyphColumns {
            release(index: index + 1, x: x + 1)
            var continuation = glyph
            continuation.isContinuation = true
            glyphs[index + 1] = continuation
        }
        hasGlyphs = true
    }

    private func release(index: Int, x: Int) {
        guard let existing = glyphs[index] else { return }
        if existing.isContinuation {
            glyphs[index - 1] = nil
        } else if x + 1 < width, glyphs[index + 1]?.isContinuation == true {
            glyphs[index + 1] = nil
        }
    }

    // MARK: Scanline fill

    /// Every run of samples inside `flattened` on a grid of `gridWidth` ×
    /// `gridHeight`, as (row, start, end) with `end` exclusive.
    ///
    /// A sample is inside when its centre is: each edge counts on the rows
    /// whose centre it spans, top included and bottom not, so two edges
    /// meeting at a vertex count once between them and no row is counted
    /// twice. Non-zero fill takes a sample whose winding number is not 0;
    /// even-odd one crossed an odd number of times (PostScript Language
    /// Reference, 3rd ed., §4.5.3). Every subpath is closed for the fill.
    func scanFill(gridWidth: Int, gridHeight: Int, evenOdd: Bool,
                  span: (_ row: Int, _ start: Int, _ end: Int) -> Void) {
        guard gridWidth > 0, gridHeight > 0 else { return }
        edges.removeAll(keepingCapacity: true)
        bucketNext.removeAll(keepingCapacity: true)
        if bucketHeads.count < gridHeight {
            bucketHeads.append(contentsOf: repeatElement(-1, count: gridHeight - bucketHeads.count))
        }
        var firstRow = gridHeight, lastRow = -1
        var begin = 0
        let lastSampleRow = Double(gridHeight - 1)
        for end in flattened.ends {
            defer { begin = end }
            guard end - begin >= 2 else { continue }
            for index in begin..<end {
                let next = index + 1 == end ? begin : index + 1
                let fromX = flattened.xs[index], fromY = flattened.ys[index]
                let toX = flattened.xs[next], toY = flattened.ys[next]
                guard fromY != toY, fromX.isFinite, fromY.isFinite, toX.isFinite, toY.isFinite else { continue }
                let downward = fromY < toY
                let topX = downward ? fromX : toX, topY = downward ? fromY : toY
                let bottomX = downward ? toX : fromX, bottomY = downward ? toY : fromY
                let top = max(0, (topY - 0.5).rounded(.up))
                let bottom = min(lastSampleRow, (bottomY - 0.5).rounded(.up) - 1)
                guard top <= bottom else { continue }
                let topRow = Int(top)
                edges.append(ScanlineEdge(
                    yTop: topY, xAtTop: topX,
                    slope: (bottomX - topX) / (bottomY - topY),
                    lastRow: Int(bottom), winding: downward ? 1 : -1))
                bucketNext.append(bucketHeads[topRow])
                bucketHeads[topRow] = edges.count - 1
                firstRow = min(firstRow, topRow)
                lastRow = max(lastRow, Int(bottom))
            }
        }
        guard firstRow <= lastRow else { return }
        active.removeAll(keepingCapacity: true)
        let columnLimit = Double(gridWidth)
        for row in firstRow...lastRow {
            var entering = bucketHeads[row]
            bucketHeads[row] = -1
            while entering >= 0 {
                active.append(entering)
                entering = bucketNext[entering]
            }
            var position = 0
            while position < active.count {
                if edges[active[position]].lastRow < row {
                    active.swapAt(position, active.count - 1)
                    active.removeLast()
                } else {
                    position += 1
                }
            }
            guard !active.isEmpty else { continue }
            let centre = Double(row) + 0.5
            crossings.removeAll(keepingCapacity: true)
            for edgeIndex in active {
                let edge = edges[edgeIndex]
                let crossing = (x: edge.xAtTop + (centre - edge.yTop) * edge.slope, winding: edge.winding)
                // Insertion sort: a scanline crosses a handful of edges.
                var slot = crossings.count
                crossings.append(crossing)
                while slot > 0, crossings[slot - 1].x > crossing.x {
                    crossings[slot] = crossings[slot - 1]
                    slot -= 1
                }
                crossings[slot] = crossing
            }
            var winding = 0
            var runStart = 0.0
            for crossing in crossings {
                let wasInside = evenOdd ? winding & 1 != 0 : winding != 0
                winding += crossing.winding
                let isInside = evenOdd ? winding & 1 != 0 : winding != 0
                if !wasInside, isInside {
                    runStart = crossing.x
                } else if wasInside, !isInside {
                    let start = max(0, (runStart - 0.5).rounded(.up))
                    let end = min(columnLimit, (crossing.x - 0.5).rounded(.up))
                    if start < end { span(row, Int(start), Int(end)) }
                }
            }
        }
    }

    // MARK: Composite

    /// Draw the planes into `buffer` at `rect`'s origin. A cell nothing
    /// was drawn in is left as it was — unless the canvas is `opaque`, or
    /// `style` gives it a background of its own, which then lies beneath
    /// everything it draws, as every other view paints the background it
    /// is given.
    func composite(into buffer: inout CellBuffer, at rect: Rect, style: Style, opaque: Bool) {
        let paintsGround = opaque || style.background != nil
        let blank = Cell(character: " ", style: style)
        var memo: (ink: UInt32, ground: Color?, result: Color?)?
        for row in 0..<height {
            let topBase = row * CanvasGrid.halfBlockRows * width
            let bottomBase = topBase + width
            for column in 0..<width {
                let index = row * width + column
                let x = rect.x + column, y = rect.y + row
                let top = ground[topBase + column], bottom = ground[bottomBase + column]
                let glyph = hasGlyphs ? glyphs[index] : nil
                let pattern = dots[index]
                if glyph?.isContinuation == true { continue }
                guard top != 0 || bottom != 0 || glyph != nil || pattern != 0 else {
                    if paintsGround { buffer[x, y] = blank }
                    continue
                }
                let beneath = paintsGround ? style.background : buffer[x, y].style.background
                let topColour = top == 0 ? beneath : inks[Int(top)].colour
                let bottomColour = bottom == 0 ? beneath : inks[Int(bottom)].colour
                // A covered cell can show only one ground: a filled half
                // over an unfilled one, and the upper half over the lower.
                let covered: Color? = top != 0 ? topColour : bottomColour

                if let glyph {
                    let background = glyph.background ?? covered
                    var foreground = glyph.foreground ?? style.foreground
                    var shows = true
                    if glyph.opacity < 1, let colour = foreground {
                        foreground = Self.blend(colour, opacity: glyph.opacity, over: background)
                        shows = foreground != nil
                    }
                    if shows {
                        buffer[x, y] = Cell(character: glyph.character, style: Style(
                            foreground: foreground, background: background,
                            bold: glyph.bold ?? style.bold, italic: glyph.italic ?? style.italic,
                            underline: glyph.underline ?? style.underline))
                        continue
                    }
                }
                if pattern != 0 {
                    let ink = inks[Int(dotInk[index])]
                    let foreground: Color?
                    if ink.opacity >= 1 {
                        foreground = ink.colour
                    } else if let memo, memo.ink == dotInk[index], memo.ground == covered {
                        foreground = memo.result
                    } else {
                        foreground = Self.blend(ink.colour, opacity: ink.opacity, over: covered)
                        memo = (dotInk[index], covered, foreground)
                    }
                    if let foreground,
                       let scalar = Unicode.Scalar(CanvasGrid.brailleBase + UInt32(pattern)) {
                        buffer[x, y] = Cell(character: Character(scalar), style: Style(
                            foreground: foreground, background: covered,
                            bold: false, italic: false, underline: false))
                        continue
                    }
                }
                // Only a translucent stroke or text that came to nothing
                // reaches here over an unfilled cell.
                guard top != 0 || bottom != 0 else {
                    if paintsGround { buffer[x, y] = blank }
                    continue
                }
                buffer[x, y] = Self.groundCell(top: topColour, bottom: bottomColour)
            }
        }
    }

    /// A cell showing `top` over `bottom`: a space when they agree, a half
    /// block when they differ.
    private static func groundCell(top: Color?, bottom: Color?) -> Cell {
        if top == bottom {
            return Cell(character: " ", style: Style(
                foreground: nil, background: top, bold: false, italic: false, underline: false))
        }
        // A half block's foreground must be a colour: nil there is the
        // terminal's default foreground, not its background.
        guard let top else {
            return Cell(character: CanvasGrid.lowerHalf, style: Style(
                foreground: bottom, background: nil, bold: false, italic: false, underline: false))
        }
        return Cell(character: CanvasGrid.upperHalf, style: Style(
            foreground: top, background: bottom, bold: false, italic: false, underline: false))
    }
}
