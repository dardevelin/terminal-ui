// Text as an editor draws it: each line word-wrapped to a width, and every
// caret position mapped to the cell it is drawn in.
//
// A caret's column is not its index. Word wrapping drops the whitespace a
// line breaks at, so a row after a wrap starts past the characters the rows
// before it hold; and a character takes the cells UAX #11 gives it — two for
// an East Asian Wide or Fullwidth one and most emoji, none for a mark that
// joins the letter before it. `TextArea` and `PromptInput` draw their rows,
// draw the caret, answer a click and move Up and Down through this one
// projection, so each lands on the cell the others name.
//
// A column over either half of a wide glyph is that glyph: the caret is a
// block over the character it stands before, as in vim and as `TextInput`
// places it, and a block drawn on a wide glyph covers both its cells. Past a
// row's last character is the row's end — the line's end on its last row,
// and before the row's last character on a row a wrap ends, as the end of
// such a row is drawn at the start of the next. Up and Down aim for a
// display column, kept across lines of any content.

/// One line of text as ``TextLayout/wrapWords(_:width:)`` lays it out: the
/// characters each display row holds, and the cell each caret position is
/// drawn in.
struct WrappedLine: Equatable, Sendable {
    /// Where the caret before a character is drawn.
    struct Caret: Equatable, Sendable {
        /// The display row, counted from the line's first.
        let row: Int
        /// The cells before the caret on its row.
        let column: Int
        /// The characters before the caret on its row: the caret is drawn
        /// on the row's character at this offset, or past the row's end.
        let offset: Int
    }

    let characters: [Character]
    /// The character offsets each display row holds, in order. A row ends
    /// where the next begins, except where the wrap dropped whitespace: that
    /// lies between them, drawn on neither.
    let rows: [Range<Int>]

    /// `line` wrapped to `width` cells, or held whole on one row when
    /// `width` is 0 or less.
    init(_ line: String, width: Int) {
        characters = Array(line)
        rows = TextLayout.wordWrapRows(characters, width: width)
    }

    /// The text drawn on `row`.
    func text(ofRow row: Int) -> String {
        String(characters[rows[row]])
    }

    /// Where the caret before character `index` is drawn. One at the end of
    /// a row a wrap ends, or in whitespace the wrap dropped, has no cell on
    /// that row and is drawn where the next row starts; one in whitespace
    /// dropped at the line's end, at the end of the last row.
    func caret(at index: Int) -> Caret {
        let index = min(max(0, index), characters.count)
        let row = rows.lastIndex { $0.lowerBound <= index } ?? 0
        let range = rows[row]
        if index >= range.upperBound && row + 1 < rows.count {
            return Caret(row: row + 1, column: 0, offset: 0)
        }
        let drawn = min(index, range.upperBound)
        let column = characters[range.lowerBound..<drawn].reduce(0) { $0 + $1.displayWidth }
        return Caret(row: row, column: column, offset: drawn - range.lowerBound)
    }

    /// The caret position drawn at `column` of `row`: before the character
    /// drawn over that cell, either half of a wide one, and past the row's
    /// last character the row's end — the line's end on the last row, and
    /// before the last character on a row a wrap ends, the last position
    /// drawn on that row.
    func index(row: Int, column: Int) -> Int {
        let row = min(max(0, row), rows.count - 1)
        let range = rows[row]
        var cellEnd = 0
        for index in range {
            cellEnd += characters[index].displayWidth
            if column < cellEnd { return index }
        }
        if row == rows.count - 1 { return characters.count }
        return range.isEmpty ? range.upperBound : range.upperBound - 1
    }
}

/// Lines of text, each wrapped to one width, read as the run of display rows
/// they are drawn in.
struct WrappedText {
    /// How many lines the text holds.
    let lineCount: Int
    private let layout: (Int) -> WrappedLine

    /// `lines`, each wrapped to `width` cells as a question needs it — so
    /// moving a caret one row wraps the lines it crosses, not the whole
    /// text. A `width` of 0 holds each line on one row.
    init(lines: [String], width: Int) {
        lineCount = lines.count
        layout = { WrappedLine(lines[$0], width: width) }
    }

    /// Lines already wrapped, as a view that draws them holds them.
    init(_ wrapped: [WrappedLine]) {
        lineCount = wrapped.count
        layout = { wrapped[$0] }
    }

    /// Line `index` laid out at the width.
    func line(_ index: Int) -> WrappedLine {
        layout(index)
    }

    /// The display rows every line takes together.
    var rowCount: Int {
        (0..<lineCount).reduce(0) { $0 + line($1).rows.count }
    }

    /// The display row the caret before character `index` of line `line`
    /// is drawn on, counted from the first row of line `firstLine`.
    func row(ofCaret index: Int, line: Int, from firstLine: Int = 0) -> Int {
        (firstLine..<line).reduce(0) { $0 + self.line($1).rows.count } + self.line(line).caret(at: index).row
    }

    /// The display column the caret before character `index` of line
    /// `line` is drawn at.
    func column(ofCaret index: Int, line: Int) -> Int {
        self.line(line).caret(at: index).column
    }

    /// The caret position drawn at `column` of display row `row`, counted
    /// from the first row of line `firstLine` — see
    /// ``WrappedLine/index(row:column:)`` — or nil past the last row.
    func caret(atRow row: Int, column: Int, from firstLine: Int = 0) -> (line: Int, index: Int)? {
        var remaining = max(0, row)
        for lineIndex in firstLine..<lineCount {
            let layout = line(lineIndex)
            if remaining < layout.rows.count {
                return (lineIndex, layout.index(row: remaining, column: column))
            }
            remaining -= layout.rows.count
        }
        return nil
    }

    /// The caret one display row above (`step` −1) or below (1) the one
    /// before character `index` of line `line`, at `column` of that row, or
    /// nil when there is no such row.
    func caret(movedBy step: Int, from index: Int, line: Int, column: Int) -> (line: Int, index: Int)? {
        let layout = self.line(line)
        let row = layout.caret(at: index).row + step
        if layout.rows.indices.contains(row) {
            return (line, layout.index(row: row, column: column))
        }
        let next = line + step
        guard (0..<lineCount).contains(next) else { return nil }
        let neighbour = self.line(next)
        return (next, neighbour.index(row: step < 0 ? neighbour.rows.count - 1 : 0, column: column))
    }
}
