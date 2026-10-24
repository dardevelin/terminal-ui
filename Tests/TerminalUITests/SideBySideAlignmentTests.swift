import Testing
@testable import TerminalUI

// Side by side, the separator sat wherever the left line ended, so a long
// removed line pushed its row's `│` out past the others and the two columns
// zig-zagged. Every left half is as wide as the widest one in view.

@Suite("Side by side, the columns line up")
@MainActor
struct SideBySideAlignmentTests {

    @Test func theSeparatorIsInOneColumnOnEveryRow() {
        let lines = DiffEngine.diff(original: "a\nlonger line here\nc", modified: "a\nshort\nc")
        let rows = renderedBuffer(DiffView(lines: lines, mode: .sideBySide), width: 60, height: 3).rowTexts
        let columns = Set(rows.map { $0.distance(from: $0.startIndex, to: $0.firstIndex(of: "│")!) })
        #expect(columns.count == 1, "\(rows)")
    }

    /// Measured in cells, not characters: a wide glyph on the left takes two.
    @Test func wideCharactersCountTheirCells() {
        let lines = DiffEngine.diff(original: "a\n日本語\nc", modified: "a\nb\nc")
        let buffer = renderedBuffer(DiffView(lines: lines, mode: .sideBySide), width: 60, height: 3)
        let separatorColumns = Set((0..<3).map { y in (0..<60).first { buffer[$0, y].character == "│" } })
        #expect(separatorColumns.count == 1)
    }
}
