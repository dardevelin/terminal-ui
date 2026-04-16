import Testing
@testable import TerminalUI

@Suite("CellBuffer")
struct CellBufferTests {

    @Test("dimensions")
    func dimensions() {
        let buffer = CellBuffer(width: 7, height: 3)
        #expect(buffer.width == 7)
        #expect(buffer.height == 3)
        #expect(buffer.cells.count == 21)
    }

    @Test("initially filled with empty cells")
    func initiallyEmpty() {
        let buffer = CellBuffer(width: 4, height: 2)
        for y in 0..<2 {
            for x in 0..<4 {
                #expect(buffer[x, y] == Cell.empty)
            }
        }
    }

    @Test("write and read back string")
    func writeAndRead() {
        var buffer = CellBuffer(width: 10, height: 2)
        buffer.write("hi", x: 0, y: 0, style: .plain)
        #expect(buffer[0, 0].character == "h")
        #expect(buffer[1, 0].character == "i")
        #expect(buffer[2, 0] == Cell.empty)
    }

    @Test("write preserves style")
    func writePreservesStyle() {
        var buffer = CellBuffer(width: 5, height: 1)
        let style = Style(foreground: .red, background: nil, bold: true, italic: false, underline: false)
        buffer.write("x", x: 0, y: 0, style: style)
        #expect(buffer[0, 0].style == style)
    }

    @Test("write clips at right edge")
    func writeClipsRight() {
        var buffer = CellBuffer(width: 3, height: 1)
        buffer.write("hello", x: 0, y: 0, style: .plain)
        #expect(buffer[0, 0].character == "h")
        #expect(buffer[1, 0].character == "e")
        #expect(buffer[2, 0].character == "l")
    }

    @Test("subscript clamps on out-of-bounds reads")
    func subscriptOutOfBoundsRead() {
        let buffer = CellBuffer(width: 5, height: 3)
        #expect(buffer[-1, 0] == Cell.empty)
        #expect(buffer[100, 0] == Cell.empty)
        #expect(buffer[0, -1] == Cell.empty)
        #expect(buffer[0, 100] == Cell.empty)
    }

    @Test("subscript ignores out-of-bounds writes")
    func subscriptOutOfBoundsWrite() {
        var buffer = CellBuffer(width: 3, height: 2)
        buffer[100, 100] = Cell(character: "!", style: .plain)
        for y in 0..<2 {
            for x in 0..<3 {
                #expect(buffer[x, y] == Cell.empty)
            }
        }
    }

    @Test("fill rectangle with character")
    func fillRect() {
        var buffer = CellBuffer(width: 5, height: 5)
        let rect = Rect(x: 1, y: 1, width: 2, height: 2)
        buffer.fill(rect, character: "X", style: .plain)
        #expect(buffer[1, 1].character == "X")
        #expect(buffer[2, 1].character == "X")
        #expect(buffer[1, 2].character == "X")
        #expect(buffer[2, 2].character == "X")
        #expect(buffer[0, 0] == Cell.empty)
        #expect(buffer[3, 3] == Cell.empty)
    }

    @Test("countDiff against identical buffer is zero")
    func countDiffIdentical() {
        var a = CellBuffer(width: 4, height: 2)
        a.write("hi", x: 0, y: 0, style: .plain)
        var b = CellBuffer(width: 4, height: 2)
        b.write("hi", x: 0, y: 0, style: .plain)
        #expect(a.countDiff(from: b) == 0)
    }

    @Test("countDiff counts changed cells")
    func countDiffChanged() {
        var a = CellBuffer(width: 4, height: 2)
        a.write("abcd", x: 0, y: 0, style: .plain)
        var b = CellBuffer(width: 4, height: 2)
        b.write("axyz", x: 0, y: 0, style: .plain)
        #expect(a.countDiff(from: b) == 3)
    }

    @Test("countDiff on size mismatch returns full area")
    func countDiffSizeMismatch() {
        let a = CellBuffer(width: 4, height: 2)
        let b = CellBuffer(width: 5, height: 2)
        #expect(a.countDiff(from: b) == 8)
    }

    @Test("countDiff against nil returns full area")
    func countDiffNilPrevious() {
        let buffer = CellBuffer(width: 3, height: 4)
        #expect(buffer.countDiff(from: nil) == 12)
    }

    @Test("writes on successive rows")
    func writeRows() {
        var buffer = CellBuffer(width: 3, height: 2)
        buffer.write("ab", x: 0, y: 0, style: .plain)
        buffer.write("cd", x: 0, y: 1, style: .plain)
        #expect(buffer[0, 0].character == "a")
        #expect(buffer[0, 1].character == "c")
        #expect(buffer[1, 1].character == "d")
    }
}
