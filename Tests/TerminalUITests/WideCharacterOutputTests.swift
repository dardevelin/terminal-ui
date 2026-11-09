import Testing
@testable import TerminalUI

// A double-width glyph (UAX #11 East Asian Wide / Fullwidth, emoji) takes
// two terminal columns, and a terminal advances its cursor by two when it
// prints one. A buffer that also emits the glyph's second cell puts that
// cell one column late, and every cell after it on the row with it. These
// tests replay the bytes the buffer emits through `TerminalReplay` and
// require the screen it ends up with to be the buffer.

/// A terminal reduced to where its cursor puts each glyph: CUP, CHA, CR, LF
/// and printable text, advancing by `displayWidth` and holding a pending
/// wrap at the last column, as xterm does with auto-wrap on (DECAWM). A
/// glyph printed over either half of a wide glyph blanks the other half,
/// as xterm does. SGR and every other sequence are consumed without effect:
/// what is under test is placement, not colour.
struct TerminalReplay {
    let width: Int
    let height: Int
    /// `nil` is the right half of the wide glyph to its left.
    private(set) var grid: [[Character?]]
    private var row = 0
    private var col = 0
    private var pendingWrap = false

    private enum Byte {
        static let escape: Unicode.Scalar = "\u{1B}"
        static let carriageReturn: Unicode.Scalar = "\r"
        static let lineFeed: Unicode.Scalar = "\n"
        static let bell: Unicode.Scalar = "\u{07}"
        static let firstPrintable: UInt32 = 0x20
        /// ECMA-48 §5.4: a control sequence ends on a byte in 0x40–0x7E.
        static let finalBytes: ClosedRange<UInt32> = 0x40...0x7E
    }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.grid = Array(repeating: Array(repeating: " ", count: width), count: height)
    }

    /// A terminal that has been sent `buffer`'s full frame.
    init(showing buffer: CellBuffer) {
        self.init(width: buffer.width, height: buffer.height)
        var out = OutputBuffer()
        buffer.renderFull(into: &out)
        feed(out.writtenBytes)
    }

    /// What each row shows, one `Character` per column, the right half of a
    /// wide glyph as a space — the shape `query_cells` dumps a buffer in.
    var rows: [String] {
        grid.map { String($0.map { $0 ?? " " }) }
    }

    mutating func feed(_ bytes: [UInt8]) {
        feed(String(decoding: bytes, as: UTF8.self))
    }

    mutating func feed(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        var run = String.UnicodeScalarView()
        var index = 0
        func flush(_ replay: inout TerminalReplay) {
            for character in String(run) { replay.put(character) }
            run.removeAll()
        }
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar.value >= Byte.firstPrintable && scalar != "\u{7F}" {
                run.append(scalar)
                continue
            }
            flush(&self)
            switch scalar {
            case Byte.carriageReturn:
                col = 0
                pendingWrap = false
            case Byte.lineFeed:
                lineFeed()
            case Byte.escape where index < scalars.count && scalars[index] == "[":
                index += 1
                var parameters = ""
                while index < scalars.count, !Byte.finalBytes.contains(scalars[index].value) {
                    parameters.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard index < scalars.count else { return }
                let final = scalars[index]
                index += 1
                controlSequence(final, parameters: parameters)
            case Byte.escape where index < scalars.count && scalars[index] == "]":
                while index < scalars.count, scalars[index] != Byte.bell, scalars[index] != Byte.escape {
                    index += 1
                }
                index += scalars[safe: index] == Byte.escape ? 2 : 1
            case Byte.escape:
                index += 1
            default:
                break
            }
        }
        flush(&self)
    }

    private mutating func controlSequence(_ final: Unicode.Scalar, parameters: String) {
        guard !parameters.hasPrefix("?") else { return }
        let numbers = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func parameter(_ position: Int) -> Int { max(1, numbers[safe: position] ?? 1) }
        switch final {
        case "H", "f":
            row = min(height, parameter(0)) - 1
            col = min(width, parameter(1)) - 1
            pendingWrap = false
        case "G":
            col = min(width, parameter(0)) - 1
            pendingWrap = false
        default:
            break
        }
    }

    private mutating func lineFeed() {
        pendingWrap = false
        if row + 1 < height {
            row += 1
        } else {
            grid.removeFirst()
            grid.append(Array(repeating: " ", count: width))
        }
    }

    private mutating func put(_ character: Character) {
        let cells = character.displayWidth
        if cells == 0 {
            var base = pendingWrap ? col : col - 1
            if base > 0, grid[row][base] == nil { base -= 1 }
            if base >= 0, let glyph = grid[row][base] {
                grid[row][base] = Character(String(glyph) + String(character))
            }
            return
        }
        if pendingWrap || col + cells > width {
            col = 0
            pendingWrap = false
            lineFeed()
        }
        erase(col)
        if cells == 2 { erase(col + 1) }
        grid[row][col] = character
        if cells == 2 { grid[row][col + 1] = nil }
        if col + cells >= width {
            col = width - 1
            pendingWrap = true
        } else {
            col += cells
        }
    }

    /// Printing over one half of a wide glyph leaves the other half blank.
    private mutating func erase(_ column: Int) {
        guard column < width else { return }
        if grid[row][column] == nil, column > 0 { grid[row][column - 1] = " " }
        if column + 1 < width, grid[row][column + 1] == nil { grid[row][column + 1] = " " }
        grid[row][column] = " "
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// What each row of `buffer` holds, one `Character` per column.
private func rows(of buffer: CellBuffer) -> [String] {
    (0..<buffer.height).map { y in String((0..<buffer.width).map { buffer[$0, y].character }) }
}

private func diffBytes(_ next: CellBuffer, from previous: CellBuffer) -> [UInt8] {
    var out = OutputBuffer()
    next.renderDiff(from: previous, into: &out)
    return out.writtenBytes
}

/// A one-row buffer holding `text` written from column 0.
private func line(_ text: String, width: Int, height: Int = 1) -> CellBuffer {
    var buffer = CellBuffer(width: width, height: height)
    buffer.write(text, x: 0, y: 0, style: .plain)
    return buffer
}

/// A terminal that showed `previous` and then got the diff to `next` shows
/// `next`.
private func expectDiffReplays(from previous: CellBuffer, to next: CellBuffer,
                               sourceLocation: SourceLocation = #_sourceLocation) {
    var terminal = TerminalReplay(showing: previous)
    #expect(terminal.rows == rows(of: previous), "full frame", sourceLocation: sourceLocation)
    terminal.feed(diffBytes(next, from: previous))
    #expect(terminal.rows == rows(of: next), "after the diff", sourceLocation: sourceLocation)
}

@Suite("Wide characters reach the terminal where the buffer holds them")
struct WideCharacterOutputTests {

    @Test("text after a CJK glyph lands two columns on, not three")
    func asciiAfterCJK() {
        let buffer = line("中a", width: 6)
        #expect(rows(of: buffer) == ["中 a   "])
        #expect(TerminalReplay(showing: buffer).rows == ["中 a   "])
    }

    @Test("a full frame never prints the second half of a wide glyph")
    func fullFrameSkipsContinuation() {
        var out = OutputBuffer()
        line("中a", width: 3).renderFull(into: &out)
        #expect(String(decoding: out.writtenBytes, as: UTF8.self) == "\u{1B}[H中a\u{1B}[0m")
    }

    @Test("a diff that changes a wide glyph rewrites it whole")
    func changedWideGlyph() {
        let previous = line("中文x", width: 6)
        let next = line("中字x", width: 6)
        expectDiffReplays(from: previous, to: next)
        #expect(String(decoding: diffBytes(next, from: previous), as: UTF8.self)
                == "\u{1B}[1;3H字\u{1B}[0m")
    }

    @Test("a wide glyph replaced by narrow ones leaves no half behind")
    func wideToNarrow() {
        expectDiffReplays(from: line("中x", width: 4), to: line("abx", width: 4))
        expectDiffReplays(from: line("中x", width: 4), to: line("a x", width: 4))
        expectDiffReplays(from: line("x中y", width: 5), to: line("xa", width: 5))
    }

    @Test("narrow glyphs replaced by a wide one leave no half behind")
    func narrowToWide() {
        expectDiffReplays(from: line("abx", width: 4), to: line("中x", width: 4))
        expectDiffReplays(from: line("abcd", width: 4), to: line("a中d", width: 4))
        expectDiffReplays(from: line("中文", width: 4), to: line("a中", width: 4))
    }

    @Test("a write over a wide glyph's right half blanks its left")
    func overwriteRightHalf() {
        let previous = line("中x", width: 4)
        var next = previous
        next[1, 0] = Cell(character: "b", style: .plain)
        #expect(rows(of: next) == [" bx "])
        expectDiffReplays(from: previous, to: next)
    }

    @Test("a write over a wide glyph's left half blanks its right")
    func overwriteLeftHalf() {
        let previous = line("中x", width: 4)
        var next = previous
        next[0, 0] = Cell(character: "a", style: .plain)
        #expect(rows(of: next) == ["a x "])
        expectDiffReplays(from: previous, to: next)
    }

    @Test("a wide glyph straddling another's halves blanks what is left of both")
    func wideOverWide() {
        let previous = line("中文", width: 4)
        var next = previous
        next.write("字", x: 1, y: 0, style: .plain)
        #expect(rows(of: next) == [" 字  "])
        expectDiffReplays(from: previous, to: next)
    }

    @Test("a wide glyph that would start in the last column is a space")
    func wideAtLastColumn() {
        let buffer = line("ab中", width: 3, height: 2)
        #expect(rows(of: buffer) == ["ab ", "   "])
        #expect(TerminalReplay(showing: buffer).rows == ["ab ", "   "])
        expectDiffReplays(from: line("abc", width: 3, height: 2), to: buffer)
    }

    @Test("a combining mark in a span of its own composes onto its base")
    func combiningMarkAcrossSpans() {
        var buffer = CellBuffer(width: 4, height: 1)
        buffer.writeSpans([TextSpan("e"), TextSpan("\u{301}"), TextSpan("x")],
                          x: 0, y: 0, maxWidth: 4, maxHeight: 1, baseStyle: .plain)
        #expect(buffer[0, 0].character == "é")
        #expect(buffer[1, 0].character == "x")
        #expect(TerminalReplay(showing: buffer).rows == rows(of: buffer))
    }

    @Test("a combining mark already in its base's grapheme is drawn with it")
    func combiningMarkInOneString() {
        let buffer = line("cafe\u{301}!", width: 6)
        #expect(buffer[3, 0].character == "e\u{301}")
        #expect(buffer[4, 0].character == "!")
        #expect(TerminalReplay(showing: buffer).rows == rows(of: buffer))
    }

    @Test("a zero-width character with no base in the write is dropped")
    func leadingMarkDropped() {
        var buffer = line("ab", width: 4)
        buffer.write("\u{301}x", x: 2, y: 0, style: .plain)
        #expect(rows(of: buffer) == ["abx "])
    }

    @Test("a zero-width character that cannot join its base is dropped, not drawn over it")
    func zeroWidthSpaceKeepsBase() {
        let buffer = line("e\u{200B}f", width: 3)
        #expect(rows(of: buffer) == ["ef "])
    }

    @Test("an emoji with a variation selector is one wide glyph")
    func emojiVariationSelector() {
        let buffer = line("🙂\u{FE0F}a", width: 4)
        #expect(buffer[0, 0].character == "🙂\u{FE0F}")
        #expect(buffer[2, 0].character == "a")
        #expect(TerminalReplay(showing: buffer).rows == rows(of: buffer))

        // U+FE0F after a text-default emoji asks for emoji presentation,
        // which is two columns (UTS #51 ED-9a).
        let heart = line("❤\u{FE0F}a", width: 4)
        #expect(heart[0, 0].character == "❤\u{FE0F}")
        #expect(heart[1, 0].isContinuation)
        #expect(heart[2, 0].character == "a")
        #expect(TerminalReplay(showing: heart).rows == rows(of: heart))

        var spans = CellBuffer(width: 4, height: 1)
        spans.writeSpans([TextSpan("🙂"), TextSpan("\u{FE0F}"), TextSpan("a")],
                         x: 0, y: 0, maxWidth: 4, maxHeight: 1, baseStyle: .plain)
        #expect(spans[0, 0].character == "🙂\u{FE0F}")
        #expect(spans[2, 0].character == "a")
    }

    @Test("a selector in a span of its own that would widen its base is dropped")
    func widenedBaseAcrossSpans() {
        // The glyph was stored one column wide and the write has moved on
        // past it: composing would take a column already handed to `a`.
        var spans = CellBuffer(width: 4, height: 1)
        spans.writeSpans([TextSpan("❤"), TextSpan("\u{FE0F}"), TextSpan("a")],
                         x: 0, y: 0, maxWidth: 4, maxHeight: 1, baseStyle: .plain)
        #expect(spans[0, 0].character == "❤")
        #expect(spans[1, 0].character == "a")
    }

    @Test("the String renderers agree with the byte renderers")
    func stringRenderers() {
        let previous = line("ab中x", width: 6)
        let next = line("中ab", width: 6)
        var full = TerminalReplay(width: 6, height: 1)
        full.feed(next.fullRender())
        #expect(full.rows == rows(of: next))
        var diffed = TerminalReplay(showing: previous)
        diffed.feed(next.diff(from: previous))
        #expect(diffed.rows == rows(of: next))
    }

    @Test("a wide glyph's second cell is its continuation, in its style")
    func continuationCell() {
        let style = Style(foreground: .red, background: .blue, bold: false, italic: false, underline: false)
        var buffer = CellBuffer(width: 4, height: 1)
        buffer.write("中", x: 0, y: 0, style: style)
        #expect(!buffer[0, 0].isContinuation)
        #expect(buffer[1, 0].isContinuation)
        #expect(buffer[1, 0].character == " ")
        #expect(buffer[1, 0].style == style)
        #expect(!buffer[2, 0].isContinuation)
    }

    @Test("a wide glyph whose second column is clipped is a space, and counts as overflow")
    func wideGlyphClipped() {
        var buffer = CellBuffer(width: 4, height: 1)
        let rejected = buffer.withClipMeasured(Rect(x: 0, y: 0, width: 2, height: 1)) { clipped in
            clipped.write("a中", x: 0, y: 0, style: .plain)
        }
        #expect(rows(of: buffer) == ["a   "])
        #expect(!buffer[2, 0].isContinuation)
        #expect(rejected == 1)
    }

    @Test("restyling a wide glyph restyles its continuation")
    func restyleLead() {
        var buffer = line("中x", width: 4)
        let bold = Style(foreground: nil, background: nil, bold: true, italic: false, underline: false)
        buffer[0, 0].style = bold
        #expect(buffer[1, 0].isContinuation)
        #expect(buffer[1, 0].style == bold)
        // Half a glyph cannot be restyled on its own.
        buffer[1, 0].style = .plain
        #expect(buffer[1, 0].isContinuation)
        #expect(buffer[1, 0].style == bold)
        #expect(buffer[0, 0].character == "中")
    }

    @Test("copying a buffer cell by cell reproduces it, in either direction")
    func cellByCellCopy() {
        var source = CellBuffer(width: 6, height: 1)
        source.write("a中🙂", x: 0, y: 0, style: .plain)
        var forward = CellBuffer(width: 6, height: 1)
        var backward = CellBuffer(width: 6, height: 1)
        for x in 0..<6 { forward[x, 0] = source[x, 0] }
        for x in (0..<6).reversed() { backward[x, 0] = source[x, 0] }
        #expect(forward.cells == source.cells)
        #expect(backward.cells == source.cells)
    }

    @Test("a continuation copied where no glyph placed one is a space")
    func orphanContinuation() {
        let source = line("中", width: 2)
        var target = line("ab", width: 2)
        target[1, 0] = source[1, 0]
        #expect(rows(of: target) == ["a "])
        #expect(!target[1, 0].isContinuation)
    }

    @Test("a transparent layer over half a wide glyph blanks the other half")
    func transparentOverlayOverHalf() {
        var base = Layer(width: 4, height: 1)
        base.buffer.write("中x", x: 0, y: 0, style: .plain)
        var overlay = Layer(width: 1, height: 1, x: 1, style: .transparent)
        overlay.buffer.write("b", x: 0, y: 0, style: .plain)
        var output = CellBuffer(width: 4, height: 1)
        Compositor.composite(layers: [base, overlay], into: &output)
        #expect(rows(of: output) == [" bx "])
        #expect(TerminalReplay(showing: output).rows == rows(of: output))
    }

    @Test("a plain-text capture shows each wide glyph once")
    func screenText() {
        #expect(line("中a", width: 4).screenText(row: 0) == "中a ")
    }

    @Test("frames of overlapping wide and narrow writes replay exactly")
    func randomFrames() {
        // A fixed linear congruential generator (Knuth, MMIX constants) so a
        // failure reproduces.
        var state: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let alphabet = ["a", "b", "中", "文", "🙂", " ", "e\u{301}", "字x"]
        let styles: [Style] = [.plain, Style(foreground: .green, background: nil,
                                             bold: true, italic: false, underline: false)]
        let width = 9, height = 3
        var previous = CellBuffer(width: width, height: height)
        var terminal = TerminalReplay(showing: previous)
        for frame in 0..<400 {
            var buffer = frame.isMultiple(of: 3) ? CellBuffer(width: width, height: height) : previous
            for _ in 0..<(1 + next(4)) {
                buffer.write(alphabet[next(alphabet.count)], x: next(width), y: next(height),
                             style: styles[next(styles.count)])
            }
            terminal.feed(diffBytes(buffer, from: previous))
            #expect(terminal.rows == rows(of: buffer), "frame \(frame)")
            if terminal.rows != rows(of: buffer) { return }
            previous = buffer
        }
    }
}
