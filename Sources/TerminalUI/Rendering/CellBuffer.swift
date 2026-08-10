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
/// what to re-emit. A double-width character (CJK, emoji) occupies two
/// cells: the glyph in the first, a styled space continuation in the
/// second.
public struct Cell: Equatable, Sendable {
    /// The grapheme cluster drawn in this cell. Control characters are
    /// refused at the ``CellBuffer`` write boundary, so a stored
    /// character is always drawable.
    public var character: Character
    /// The resolved visual attributes this cell is drawn with.
    public var style: Style

    /// Create a cell from a character and a fully resolved style.
    public init(character: Character, style: Style) {
        self.character = character
        self.style = style
    }

    /// A blank cell: a space with ``Style/plain``. The state every cell
    /// starts in after `clear()`, and what transparent compositing
    /// treats as "no content".
    public static let empty = Cell(character: " ", style: .plain)
}

// Make Color equatable for Cell diffing
extension Color: Equatable {
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
    public subscript(x: Int, y: Int) -> Cell {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return .empty }
            return cells[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            // A cell holds a rendered glyph. `OutputBuffer.writeCharacter`
            // copies cell bytes verbatim to the file descriptor, so a stored
            // control character is executed by the terminal rather than drawn
            // — any string the program does not control (a filename, a chat
            // message, a branch name) could move the cursor or clear the
            // screen. Refused here, at the same choke point that enforces
            // clipping, so no writer can forget to filter.
            guard !newValue.character.isTerminalControl else { return }
            if let clip = clipRect {
                guard x >= clip.x, x < clip.x + clip.width,
                      y >= clip.y, y < clip.y + clip.height else {
                    // Record the rejection so the renderer can
                    // attribute overflow to the offending child via
                    // `withClipMeasured`'s delta. Cheaper than tracking
                    // per-cell positions; the renderer only needs a
                    // count to decide "did this child overflow at all."
                    clipRejectedWrites += 1
                    return
                }
            }
            cells[y * width + x] = newValue
        }
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
    /// Advances by each character's `displayWidth` — double-wide glyphs
    /// take two cells (glyph + styled continuation space), zero-width
    /// combining marks compose onto the previous cell. Clips at the
    /// buffer's right edge; does not wrap and does not interpret
    /// newlines (use `writeSpans` for wrapping multi-line output).
    public mutating func write(_ text: String, x: Int, y: Int, style: Style) {
        var col = x
        for char in text {
            guard col < width else { break }
            // Skipped before the zero-width branch below: that branch exists to
            // compose combining marks onto their base glyph, which is right for
            // U+0301 and wrong for U+001B — merging a control would both store
            // it and destroy the character it merged onto.
            if char.isTerminalControl { continue }
            let w = char.displayWidth
            if w == 0 {
                if col > x {
                    self[col - 1, y] = Cell(character: char, style: style)
                }
                continue
            }
            self[col, y] = Cell(character: char, style: style)
            if w == 2 && col + 1 < width {
                self[col + 1, y] = Cell(character: " ", style: style)
            }
            col += w
        }
    }

    /// Write styled spans, handling newlines within spans. Each span resolves its
    /// style overrides against the base style. Clips to maxWidth × maxHeight.
    public mutating func writeSpans(_ spans: [TextSpan], x: Int, y: Int,
                                     maxWidth: Int, maxHeight: Int, baseStyle: Style,
                                     wrap: Bool = true) {
        var col = x
        var row = y
        let maxX = x + maxWidth
        let maxY = y + maxHeight

        for span in spans {
            let style = span.resolved(over: baseStyle)
            for char in span.text {
                if char == "\n" {
                    row += 1
                    col = x
                    guard row < maxY else { return }
                    continue
                }
                let w = char.displayWidth
                // Zero-width: compose onto previous base cell, no advance.
                if w == 0 {
                    if col > x {
                        self[col - 1, row] = Cell(character: char, style: style)
                    }
                    continue
                }
                // Wrap or clip when this grapheme wouldn't fit on the
                // current line. Double-wide chars wrap as a unit — never
                // split across rows.
                if col + w > maxX {
                    if wrap {
                        // Wrap to next line
                        row += 1
                        col = x
                        guard row < maxY else { return }
                    } else {
                        continue // clip
                    }
                }
                guard row < maxY else { return }
                self[col, row] = Cell(character: char, style: style)
                if w == 2 && col + 1 < maxX {
                    self[col + 1, row] = Cell(character: " ", style: style)
                }
                col += w
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
    /// tests, at String-allocation cost.
    public func diff(from previous: CellBuffer?) -> String {
        guard let previous, previous.width == width, previous.height == height else {
            return fullRender()
        }

        var output = ""
        var lastStyle = Style.plain

        for y in 0..<height {
            for x in 0..<width {
                let cell = self[x, y]
                let prev = previous[x, y]
                if cell != prev {
                    output += "\u{1B}[\(y + 1);\(x + 1)H"
                    if cell.style != lastStyle {
                        output += styleToAnsi(cell.style)
                        lastStyle = cell.style
                    }
                    output += String(cell.character)
                }
            }
        }

        output += "\u{1B}[0m"
        return output
    }

    // MARK: - Direct byte buffer rendering

    /// Render full frame into an OutputBuffer — zero String allocation
    public func renderFull(into out: inout OutputBuffer) {
        out.reset()
        out.writeCSI()
        out.write(0x48) // 'H' — cursor home

        var lastStyle = Style.plain
        for y in 0..<height {
            for x in 0..<width {
                let cell = self[x, y]
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
                let cell = self[x, y]
                let prev = previous[x, y]

                if cell == prev {
                    x += 1
                    continue
                }

                // Found a changed cell. Position cursor if not already there.
                if cursorRow != y || cursorCol != x {
                    out.writeCursorPosition(row: y + 1, col: x + 1)
                }

                // Write this cell and any consecutive changed cells
                while x < width {
                    let c = self[x, y]
                    let p = previous[x, y]

                    // Stop the run if we hit an unchanged cell
                    // BUT: if the gap to the next changed cell is small (< 4),
                    // it's cheaper to overwrite than to emit a new cursor position
                    if c == p {
                        // Look ahead for nearby changes
                        var nextDirty = x + 1
                        while nextDirty < min(x + 4, width) {
                            if self[nextDirty, y] != previous[nextDirty, y] { break }
                            nextDirty += 1
                        }
                        if nextDirty < x + 4 && nextDirty < width && self[nextDirty, y] != previous[nextDirty, y] {
                            // Small gap — cheaper to overwrite than reposition
                        } else {
                            break
                        }
                    }

                    let current = self[x, y]
                    if current.style != lastStyle {
                        out.writeStyle(current.style)
                        lastStyle = current.style
                    }
                    out.writeCharacter(current.character)
                    x += 1
                }

                cursorRow = y
                cursorCol = x
            }
        }
        out.writeReset()
    }

    // MARK: - String-based rendering (used by frame capture)

    func fullRender() -> String {
        var output = "\u{1B}[H" // cursor home
        var lastStyle = Style.plain

        for y in 0..<height {
            for x in 0..<width {
                let cell = self[x, y]
                if cell.style != lastStyle {
                    output += styleToAnsi(cell.style)
                    lastStyle = cell.style
                }
                output += String(cell.character)
            }
            if y < height - 1 {
                output += "\r\n"
            }
        }

        output += "\u{1B}[0m"
        return output
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
