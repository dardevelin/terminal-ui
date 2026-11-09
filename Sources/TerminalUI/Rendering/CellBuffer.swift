/// The fully resolved visual attributes of one terminal cell: foreground,
/// background, and the bold/italic/underline flags.
///
/// This is the *resolved* form — unlike ``TextSpan``, whose optional
/// fields inherit from context, a `Style` answers every attribute
/// (`nil` color here means the terminal's default, not "inherit").
/// Every ``Cell`` in a ``CellBuffer`` carries one; the output stage
/// emits an SGR sequence only when the style differs from the previous
/// cell's, so runs of uniform style cost nothing extra on the wire.
public struct Style: Equatable, Sendable {
    /// Text color; `nil` leaves the terminal's default foreground (SGR 39).
    public var foreground: Color?
    /// Fill color behind the character; `nil` leaves the terminal's
    /// default background (SGR 49).
    public var background: Color?
    /// Bold weight (SGR 1). Some terminal themes render this as a
    /// brighter color instead of, or as well as, a heavier font.
    public var bold: Bool
    /// Italic slant (SGR 3). Not all terminal fonts carry an italic
    /// face; unsupported terminals ignore it.
    public var italic: Bool
    /// Underline (SGR 4).
    public var underline: Bool

    /// Memberwise initializer — every attribute is required so a `Style`
    /// is always fully resolved. For partial styling that inherits from
    /// context, use ``TextSpan`` or the view modifiers instead.
    public init(foreground: Color?, background: Color?, bold: Bool, italic: Bool, underline: Bool) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    /// No attributes: default terminal colors, no bold/italic/underline.
    /// The style of an ``Cell/empty`` cell and the baseline the output
    /// stage resets to between styled runs.
    public static let plain = Style(foreground: nil, background: nil, bold: false, italic: false, underline: false)
}

/// One cell of the terminal grid: a single grapheme cluster plus its
/// resolved ``Style``.
///
/// The atom of the render pipeline — every frame is a ``CellBuffer`` of
/// these, and the delta pass compares cells by simple equality to decide
/// what to re-emit.
///
/// A double-width character (UAX #11 East Asian Wide or Fullwidth, most
/// emoji) occupies two cells: the glyph in the first, and in the second a
/// cell whose ``isContinuation`` is `true`. A terminal draws the glyph
/// across both columns and advances its cursor by two, so the output
/// stage never sends a continuation cell — sending it would put
/// everything after it on the row one column late.
public struct Cell: Equatable, Sendable {
    /// The grapheme cluster drawn in this cell. Control characters are
    /// refused at the ``CellBuffer`` write boundary, so a stored
    /// character is always drawable. A continuation cell holds a space,
    /// so a reader that lays one character out per column still lines up.
    public var character: Character
    /// The resolved visual attributes this cell is drawn with. A
    /// continuation cell carries its glyph's style: the terminal draws
    /// both columns with the attributes the glyph was printed with.
    public var style: Style
    /// Whether this cell is the right half of the double-width glyph in
    /// the cell to its left.
    ///
    /// Only a ``CellBuffer`` makes one, when it stores a double-width
    /// glyph, and it keeps the pair whole: a write over either half
    /// blanks the other, as a terminal does.
    public private(set) var isContinuation: Bool

    /// Create a cell from a character and a fully resolved style.
    public init(character: Character, style: Style) {
        self.character = character
        self.style = style
        self.isContinuation = false
    }

    /// The right half of a double-width glyph drawn in `style`.
    static func continuation(style: Style) -> Cell {
        var cell = Cell(character: " ", style: style)
        cell.isContinuation = true
        return cell
    }

    /// A blank cell: a space with ``Style/plain``. The state every cell
    /// starts in after `clear()`, and what transparent compositing
    /// treats as "no content".
    public static let empty = Cell(character: " ", style: .plain)
}

// Make Color equatable for Cell diffing
extension Color: Equatable {
    /// Compares how a colour is encoded, not how it looks: `.red`,
    /// `.ansi256(1)` and an RGB that matches the terminal's red are three
    /// different values, because each emits a different SGR sequence.
    public static func == (lhs: Color, rhs: Color) -> Bool {
        switch (lhs, rhs) {
        case (.default, .default),
             (.black, .black),
             (.red, .red),
             (.green, .green),
             (.yellow, .yellow),
             (.blue, .blue),
             (.magenta, .magenta),
             (.cyan, .cyan),
             (.white, .white),
             (.gray, .gray),
             (.brightRed, .brightRed),
             (.brightGreen, .brightGreen),
             (.brightYellow, .brightYellow),
             (.brightBlue, .brightBlue),
             (.brightMagenta, .brightMagenta),
             (.brightCyan, .brightCyan),
             (.brightWhite, .brightWhite):
            true
        case (.ansi256(let a), .ansi256(let b)):
            a == b
        case (.rgb(let r1, let g1, let b1), .rgb(let r2, let g2, let b2)):
            r1 == r2 && g1 == g2 && b1 == b2
        default:
            false
        }
    }
}

/// A width × height grid of ``Cell``s — the in-memory frame the render
/// pipeline draws into before anything touches the terminal.
///
/// In the pipeline, `GraphRenderer` walks the attribute graph and writes
/// each node's output here (through the clipping subscript and the
/// width-aware text writers); the `Compositor` merges per-layer buffers;
/// and the delta pass (``renderDiff(from:into:)``) compares this frame
/// against the previous one to emit only changed cells into an
/// ``OutputBuffer``. All coordinates are cells, origin (0, 0) at the
/// top-left; out-of-bounds reads return ``Cell/empty`` and out-of-bounds
/// writes are dropped, so callers never bounds-check.
public struct CellBuffer: Sendable {
    /// Grid width in cells (terminal columns).
    public var width: Int
    /// Grid height in cells (terminal rows).
    public var height: Int
    /// Readable for compositing and diffing; writes go through the subscript so
    /// they cannot skip clip enforcement or control-character refusal.
    public private(set) var cells: [Cell]

    /// Optional clip rectangle — when set, writes to cells outside this rect are
    /// dropped silently. Renderer pushes the current component's assigned rect
    /// before descending and pops on return, giving framework-enforced rect
    /// boundaries without asking every component to self-clip.
    ///
    /// The bounds check in the subscript setter AND in text-writing helpers
    /// (`write`, `writeSpans`) consults this rect intersected with the buffer
    /// dimensions. Reads are never clipped — they return `.empty` outside the
    /// buffer but are otherwise unrestricted.
    public var clipRect: Rect?

    /// Total cell writes the active `clipRect` has rejected since
    /// the last `clear()`. The renderer compares the delta across
    /// each child's `withClipMeasured` scope to detect which
    /// component overflowed its assigned rect and emit a one-shot
    /// `componentOverflow` framework warning per offending node per
    /// frame. Cleared with the rest of the buffer.
    ///
    /// In debug builds it excludes the writes an `.overflowOK()` subtree
    /// excused: the renderer takes them back out as it leaves each node
    /// that allows overflow, so no enclosing scope counts them either.
    ///
    /// Note: writes that fall outside the buffer dimensions (e.g.,
    /// negative coordinates from a layout bug) DO NOT count as
    /// "overflow" — those are tracked via the always-on bounds check
    /// in the subscript setter, which returns before the clip check.
    /// Only writes inside the buffer but outside the clip increment
    /// this counter.
    public var clipRejectedWrites: Int = 0

    /// Create a buffer of the given cell dimensions, every cell
    /// ``Cell/empty``, with no clip. Per-frame reuse should prefer
    /// `clear()` / `resize(width:height:)`, which keep the existing
    /// allocation.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.cells = Array(repeating: .empty, count: width * height)
        self.clipRect = nil
    }

    /// Reset every cell to `.empty` and drop any clip. Cheaper than
    /// constructing a fresh `CellBuffer` per frame: the underlying
    /// storage capacity is preserved, so subsequent renders skip the
    /// allocator entirely. Safe to call from any frame
    /// boundary — callers that resize between frames should use
    /// `resize(width:height:)` instead.
    public mutating func clear() {
        // `withUnsafeMutableBufferPointer` lets the optimiser turn this
        // into a single memset-style fill rather than per-element store.
        cells.withUnsafeMutableBufferPointer { buf in
            for i in 0..<buf.count {
                buf[i] = .empty
            }
        }
        clipRect = nil
        clipRejectedWrites = 0
    }

    /// Resize in place. Reallocates only if the new dimensions differ from
    /// the current buffer; otherwise just clears. Frame-stable callers
    /// (the runtime) prefer this over `init(width:height:)` to keep the
    /// hot path allocation-free outside of resize events.
    public mutating func resize(width: Int, height: Int) {
        if width == self.width && height == self.height {
            clear()
            return
        }
        self.width = width
        self.height = height
        self.cells = Array(repeating: .empty, count: width * height)
        self.clipRect = nil
        self.clipRejectedWrites = 0
    }

    /// Cell access by column and row (cells, origin top-left). Reads
    /// outside the buffer return ``Cell/empty``; writes outside the
    /// buffer or the active `clipRect` are dropped, and control
    /// characters are refused — this subscript is the single choke
    /// point for both guarantees, so no writer can bypass them.
    ///
    /// It also keeps every double-width glyph whole, as a terminal does
    /// (xterm erases the rest of a wide character any write lands on):
    ///
    /// - A double-width character fills this cell and the next, which
    ///   becomes its continuation (``Cell/isContinuation``). Where that
    ///   next column is past the buffer's edge or outside the clip, the
    ///   glyph cannot be drawn at all, and the cell gets a space in its
    ///   style instead — as terminals and editors leave the last column
    ///   when a wide glyph does not fit.
    /// - A write onto either half of a wide glyph already here blanks the
    ///   other half, keeping its style, even where that half is outside
    ///   the clip: half a glyph is not something a terminal can show.
    /// - A continuation cell assigned here, as a compositor copying cells
    ///   from another buffer does, is kept only where the glyph to its
    ///   left already placed one; anywhere else it is a space.
    public subscript(x: Int, y: Int) -> Cell {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return .empty }
            return cells[y * width + x]
        }
        set {
            store(newValue, x: x, y: y)
        }
    }

    /// Store `cell` at (x, y) under the guarantees the subscript documents,
    /// and report whether the cell now draws the glyph it was given —
    /// `false` when the write was refused, clipped, or turned into a space
    /// because the glyph's second column was not available.
    @discardableResult
    mutating func store(_ cell: Cell, x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        // A cell holds a rendered glyph. `OutputBuffer.writeCharacter`
        // copies cell bytes verbatim to the file descriptor, so a stored
        // control character is executed by the terminal rather than drawn
        // — any string the program does not control (a filename, a chat
        // message, a branch name) could move the cursor or clear the
        // screen. Refused here, at the same choke point that enforces
        // clipping, so no writer can forget to filter.
        guard !cell.character.isTerminalControl else { return false }
        guard admitsWrite(x: x, y: y) else { return false }
        let index = y * width + x
        if cell.isContinuation {
            if cells[index].isContinuation { return true }
            release(x: x, y: y)
            cells[index] = Cell(character: " ", style: cell.style)
            return false
        }
        release(x: x, y: y)
        guard cell.character.displayWidth == Self.wideGlyphColumns else {
            cells[index] = cell
            return true
        }
        guard x + 1 < width, admitsWrite(x: x + 1, y: y) else {
            cells[index] = Cell(character: " ", style: cell.style)
            return false
        }
        release(x: x + 1, y: y)
        cells[index] = cell
        cells[index + 1] = .continuation(style: cell.style)
        return true
    }

    /// Columns a double-width glyph covers (UAX #11 W and F).
    private static let wideGlyphColumns = 2

    /// Whether the clip admits a write at an in-buffer (x, y), counting the
    /// rejection when it does not — the renderer attributes overflow to the
    /// offending child through `withClipMeasured`'s delta. Cheaper than
    /// tracking per-cell positions; the renderer only needs a count to
    /// decide "did this child overflow at all."
    private mutating func admitsWrite(x: Int, y: Int) -> Bool {
        guard let clip = clipRect else { return true }
        guard x >= clip.x, x < clip.x + clip.width,
              y >= clip.y, y < clip.y + clip.height else {
            clipRejectedWrites += 1
            return false
        }
        return true
    }

    /// Blank the other half of a wide glyph that the cell at (x, y) is part
    /// of, ahead of a write there.
    private mutating func release(x: Int, y: Int) {
        let index = y * width + x
        if cells[index].isContinuation {
            cells[index - 1] = Cell(character: " ", style: cells[index - 1].style)
        } else if x + 1 < width, cells[index + 1].isContinuation {
            cells[index + 1] = Cell(character: " ", style: cells[index + 1].style)
        }
    }

    /// Join a zero-width character onto the glyph at (x, y), which the
    /// calling writer drew. Swift's `Character` is a UAX #29 extended
    /// grapheme cluster, so a combining mark, a variation selector or a
    /// ZWJ after its base joins it (GB9, GB9a) and is drawn with it — the
    /// mark arriving in a span of its own is what reaches here. A
    /// zero-width character that does not join (U+200B is a grapheme of
    /// its own), or that would change how many columns its base takes,
    /// has nothing to draw in a cell grid and is dropped.
    private mutating func compose(_ mark: Character, x: Int, y: Int) {
        let base = self[x, y]
        let joined = String(base.character) + String(mark)
        guard joined.count == 1, let glyph = joined.first,
              glyph.displayWidth == base.character.displayWidth else { return }
        store(Cell(character: glyph, style: base.style), x: x, y: y)
    }

    /// Run `body` with `clipRect` temporarily set to the intersection of the
    /// existing clip and `rect`. Restores the prior clip on return, even if
    /// body throws. Intersection (not replacement) is critical — a child
    /// cannot escape its ancestors' clips.
    @inlinable
    public mutating func withClip<R>(_ rect: Rect, _ body: (inout CellBuffer) throws -> R) rethrows -> R {
        let prev = clipRect
        clipRect = prev.map { $0.intersected(with: rect) } ?? rect
        defer { clipRect = prev }
        return try body(&self)
    }

    /// `withClip` variant that returns the count of writes rejected
    /// by the clip during `body`'s execution. The renderer uses this
    /// delta to attribute overflow to the specific child node and
    /// emit a one-shot framework warning per offending node per
    /// frame. Body's return value is ignored — only the rejection
    /// delta surfaces. Use the regular `withClip` when you don't
    /// need the count (cheaper: no snapshot/diff).
    @inlinable
    public mutating func withClipMeasured<R>(_ rect: Rect, _ body: (inout CellBuffer) throws -> R) rethrows -> Int {
        let prev = clipRect
        let baseline = clipRejectedWrites
        clipRect = prev.map { $0.intersected(with: rect) } ?? rect
        defer { clipRect = prev }
        _ = try body(&self)
        return clipRejectedWrites - baseline
    }

    /// Write a single line of text starting at (x, y), one uniform style.
    ///
    /// Advances by each character's `displayWidth`: a double-width glyph
    /// takes two cells (see the subscript), and a zero-width character
    /// joins the glyph this call drew before it when Swift's grapheme
    /// rules allow, and is dropped otherwise — including at the start of
    /// the write, where the cell to the left belongs to someone else.
    /// Clips at the buffer's right edge; does not wrap and does not
    /// interpret newlines (use `writeSpans` for wrapping multi-line output).
    public mutating func write(_ text: String, x: Int, y: Int, style: Style) {
        var col = x
        // The column of the glyph this call last drew, which a following
        // zero-width character joins; nil while there is none to join.
        var base: Int?
        for char in text {
            guard col < width else { break }
            // Skipped before the zero-width branch below: that branch exists to
            // compose combining marks onto their base glyph, which is right for
            // U+0301 and wrong for U+001B.
            if char.isTerminalControl { continue }
            let columns = char.displayWidth
            if columns == 0 {
                if let base { compose(char, x: base, y: y) }
                continue
            }
            base = store(Cell(character: char, style: style), x: col, y: y) ? col : nil
            col += columns
        }
    }

    /// Write styled spans, handling newlines within spans. Each span resolves its
    /// style overrides against the base style. Clips to maxWidth × maxHeight.
    ///
    /// Widths and zero-width characters are handled as in
    /// ``write(_:x:y:style:)``, across span boundaries: a combining mark
    /// in a span of its own joins the glyph the span before it ended on.
    /// A double-width glyph is never split across rows. Without `wrap`,
    /// the first glyph that does not fit ends its line: nothing after it
    /// is drawn until the next newline.
    public mutating func writeSpans(_ spans: [TextSpan], x: Int, y: Int,
                                     maxWidth: Int, maxHeight: Int, baseStyle: Style,
                                     wrap: Bool = true) {
        var col = x
        var row = y
        let maxX = x + maxWidth
        let maxY = y + maxHeight
        var base: Int?
        var lineClipped = false

        for span in spans {
            let style = span.resolved(over: baseStyle)
            for char in span.text {
                // CRLF is one grapheme cluster (UAX #29 GB3), so `"\r\n"`
                // never compares equal to `"\n"`.
                if char == "\n" || char == "\r\n" {
                    row += 1
                    col = x
                    base = nil
                    lineClipped = false
                    guard row < maxY else { return }
                    continue
                }
                if char.isTerminalControl || lineClipped { continue }
                let columns = char.displayWidth
                if columns == 0 {
                    if let base { compose(char, x: base, y: row) }
                    continue
                }
                if col + columns > maxX {
                    guard wrap else {
                        lineClipped = true
                        base = nil
                        continue
                    }
                    row += 1
                    col = x
                    guard row < maxY else { return }
                }
                guard row < maxY else { return }
                base = store(Cell(character: char, style: style), x: col, y: row) ? col : nil
                col += columns
            }
        }
    }

    /// Fill every cell of `rect` with one character and style —
    /// backgrounds, dividers, and blanking regions before a redraw.
    /// The rect is clamped to the buffer, so out-of-bounds or empty
    /// rects are a safe no-op.
    public mutating func fill(_ rect: Rect, character: Character = " ", style: Style = .plain) {
        // Clamp origin + extent to the buffer so negative, overflowing, or
        // fully-off-screen rects produce an empty range instead of crashing
        // with `Range requires lowerBound <= upperBound`. Layout passes
        // sometimes hand a rect that sits past the buffer (e.g. when a
        // VStack allocates beyond its parent under tight measurements);
        // the renderer should silently no-op rather than panic. The
        // subscript setter already bounds per-cell writes.
        let startRow = max(0, min(rect.y, height))
        let endRow = max(startRow, min(rect.y + rect.height, height))
        let startCol = max(0, min(rect.x, width))
        let endCol = max(startCol, min(rect.x + rect.width, width))
        guard endRow > startRow, endCol > startCol else { return }
        for row in startRow..<endRow {
            for col in startCol..<endCol {
                self[col, row] = Cell(character: character, style: style)
            }
        }
    }

    /// Count how many cells differ from previous buffer.
    /// A dimension mismatch (or `nil`) counts every cell — the same
    /// condition under which the diff renderers fall back to a full
    /// redraw.
    public func countDiff(from previous: CellBuffer?) -> Int {
        guard let previous, previous.width == width, previous.height == height else {
            return width * height
        }
        var count = 0
        for i in 0..<cells.count {
            if cells[i] != previous.cells[i] { count += 1 }
        }
        return count
    }

    /// String-building counterpart of ``renderDiff(from:into:)``: the
    /// ANSI sequence (cursor moves + SGR + changed characters) that
    /// updates a terminal showing `previous` to show this frame. Falls
    /// back to a full-frame render when `previous` is `nil` or sized
    /// differently. The hot path uses `renderDiff` into an
    /// ``OutputBuffer`` instead; this form serves frame capture and
    /// tests, at String-allocation cost. It is that same output, decoded,
    /// so what a capture holds is what the terminal was sent.
    public func diff(from previous: CellBuffer?) -> String {
        var out = OutputBuffer()
        renderDiff(from: previous, into: &out)
        return String(decoding: out.writtenBytes, as: UTF8.self)
    }

    // MARK: - Direct byte buffer rendering

    /// Render full frame into an OutputBuffer — zero String allocation.
    /// A double-width glyph is sent once: the terminal draws it across
    /// both its cells, so its continuation cell is never written.
    public func renderFull(into out: inout OutputBuffer) {
        out.reset()
        out.writeCSI()
        out.write(0x48) // 'H' — cursor home

        var lastStyle = Style.plain
        for y in 0..<height {
            for x in 0..<width {
                let cell = self[x, y]
                if cell.isContinuation { continue }
                if cell.style != lastStyle {
                    out.writeStyle(cell.style)
                    lastStyle = cell.style
                }
                out.writeCharacter(cell.character)
            }
            if y < height - 1 {
                out.write(0x0D) // \r
                out.write(0x0A) // \n
            }
        }
        out.writeReset()
    }

    /// Delta rendering: compare against the previous frame's buffer, emit only changed cells.
    ///
    /// Optimization: gap bridging. When a small gap (< 4 cells) of unchanged cells
    /// separates two runs of changes on the same row, we overwrite the gap rather
    /// than emitting a new cursor position sequence.
    ///
    /// Cost model: cursor move (CSI row;colH) costs ~8-10 bytes. Overwriting 1-3
    /// unchanged cells costs 1-3 bytes. Bridging small gaps saves bytes and reduces
    /// terminal parse overhead — especially important over SSH where latency dominates.
    ///
    /// A double-width glyph is written whole: a run that reaches either of
    /// its cells starts at the glyph and steps over both, as the terminal's
    /// cursor does. Because a buffer blanks what is left of any glyph a
    /// write splits, every cell a terminal erases when a glyph changes
    /// width also differs from the previous frame, and is written again.
    public func renderDiff(from previous: CellBuffer?, into out: inout OutputBuffer) {
        out.reset()
        guard let previous, previous.width == width, previous.height == height else {
            renderFull(into: &out)
            return
        }

        var lastStyle = Style.plain
        var cursorRow = -1
        var cursorCol = -1

        for y in 0..<height {
            var x = 0
            while x < width {
                guard changed(x, y, from: previous) else {
                    x += 1
                    continue
                }
                if x > 0, self[x, y].isContinuation { x -= 1 }

                if cursorRow != y || cursorCol != x {
                    out.writeCursorPosition(row: y + 1, col: x + 1)
                }

                let runStart = x
                while x < width {
                    // An unchanged cell ends the run unless another change
                    // follows close enough that rewriting the gap is
                    // cheaper than repositioning.
                    if x > runStart, !changed(x, y, from: previous),
                       !changeAhead(of: x, y, from: previous) {
                        break
                    }
                    let current = self[x, y]
                    if current.style != lastStyle {
                        out.writeStyle(current.style)
                        lastStyle = current.style
                    }
                    out.writeCharacter(current.character)
                    x += columns(at: x, y)
                }

                cursorRow = y
                cursorCol = x
            }
        }
        out.writeReset()
    }

    /// Unchanged cells a diff run rewrites rather than move the cursor past
    /// them: a CUP costs 6–10 bytes, a narrow cell 1–4.
    private static let bridgedGap = 3

    private func changed(_ x: Int, _ y: Int, from previous: CellBuffer) -> Bool {
        self[x, y] != previous[x, y]
    }

    /// Whether a changed cell lies within ``bridgedGap`` cells after `x`.
    private func changeAhead(of x: Int, _ y: Int, from previous: CellBuffer) -> Bool {
        let end = min(x + Self.bridgedGap + 1, width)
        guard x + 1 < end else { return false }
        return (x + 1..<end).contains { changed($0, y, from: previous) }
    }

    /// Columns the glyph at (x, y) takes on the terminal: two when the cell
    /// to its right is its continuation.
    private func columns(at x: Int, _ y: Int) -> Int {
        x + 1 < width && self[x + 1, y].isContinuation ? Self.wideGlyphColumns : 1
    }

    // MARK: - String-based rendering (used by frame capture)

    /// ``renderFull(into:)``'s output as a String, for frame capture.
    func fullRender() -> String {
        var out = OutputBuffer()
        renderFull(into: &out)
        return String(decoding: out.writtenBytes, as: UTF8.self)
    }

    /// Row `y` as it reads on screen: each glyph once, a double-width one
    /// without its continuation — for the plain-text captures people open
    /// in an editor, where the continuation's space would push the rest of
    /// the row out of line.
    func screenText(row y: Int) -> String {
        var line = ""
        for x in 0..<width where !self[x, y].isContinuation {
            line.append(self[x, y].character)
        }
        return line
    }
    func styleToAnsi(_ style: Style) -> String {
        var codes = "\u{1B}[0m"
        if let fg = style.foreground {
            codes += fg.foregroundCode
        }
        if let bg = style.background {
            codes += bg.backgroundCode
        }
        if style.bold { codes += "\u{1B}[1m" }
        if style.italic { codes += "\u{1B}[3m" }
        if style.underline { codes += "\u{1B}[4m" }
        return codes
    }
}
