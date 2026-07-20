import Testing
@testable import TerminalUI

// A cell holds one *rendered glyph*. Control characters are not glyphs — they
// are instructions to the terminal, and a buffer that stores one emits it
// verbatim on the next flush, because `OutputBuffer.writeCharacter` copies cell
// bytes straight to the file descriptor.
//
// That makes any string a program does not control — a filename, a chat
// message, a git branch, an HTTP response — able to move the cursor, clear the
// screen, or change colours outside the framework's compositing. The framework
// already treats leaked escape state as a security concern on the way out
// (signal and atexit handlers restore the terminal); this is the same concern
// on the way in.
//
// Two defects, one cause. `CellBuffer.write` gave zero-width characters the
// "combining mark" treatment — merge onto the previous cell — which is right
// for U+0301 and wrong for U+001B. So a control character both reached the
// terminal *and* destroyed the glyph it merged onto.

private let plain = Style(
    foreground: nil, background: nil, bold: false, italic: false, underline: false
)

@MainActor
private func rendered(_ text: String, width: Int = 12) -> String {
    var buffer = CellBuffer(width: width, height: 1)
    buffer.write(text, x: 0, y: 0, style: plain)
    var out = ""
    for x in 0..<width {
        out.append(buffer[x, 0].character)
    }
    return out.trimmingCharacters(in: .whitespaces)
}

/// Counts cells holding a control scalar, deliberately spelled out rather than
/// calling `isTerminalControl`. Measuring with the predicate under test makes
/// the detector and the assertion fail together: weakening the predicate would
/// also stop the test seeing what leaked, and every case would still pass.
@MainActor
private func controlCellCount(_ buffer: CellBuffer, width: Int, height: Int = 1) -> Int {
    var count = 0
    for y in 0..<height {
        for x in 0..<width {
            for scalar in buffer[x, y].character.unicodeScalars
            where scalar.value < 0x20
                || scalar.value == 0x7F
                || (0x80...0x9F).contains(scalar.value) {
                count += 1
            }
        }
    }
    return count
}

@MainActor
private func controlCells(_ text: String, width: Int = 12) -> Int {
    var buffer = CellBuffer(width: width, height: 1)
    buffer.write(text, x: 0, y: 0, style: plain)
    return controlCellCount(buffer, width: width)
}

@Suite("Control characters never reach a cell")
@MainActor
struct ControlCharacterSanitizationTests {

    @Test("an escape sequence in user text does not reach the buffer")
    func escapeAfterTextIsDropped() {
        // The original report's case. Leading controls were already dropped
        // because the merge branch requires a previous cell, which hid this.
        #expect(controlCells("ab\u{1B}[2Jc") == 0)
    }

    @Test("an escape does not destroy the glyph before it")
    func escapeDoesNotOverwritePrecedingGlyph() {
        // Merging ESC onto the previous cell replaced a legitimate character.
        #expect(rendered("ab\u{1B}[2Jc") == "ab[2Jc")
    }

    @Test("every C0 control and DEL is refused",
          arguments: Array(0..<0x20) + [0x7F])
    func controlScalarIsRefused(value: Int) {
        let control = Character(Unicode.Scalar(value)!)
        #expect(controlCells("a\(control)b") == 0)
    }

    @Test("C1 controls are refused")
    func c1ControlsRefused() {
        // U+0080–U+009F are single-scalar equivalents of ESC-prefixed
        // sequences; a terminal in an 8-bit mode acts on them directly.
        #expect(controlCells("a\u{9B}b") == 0, "CSI (U+009B) reached a cell")
    }

    @Test("a CRLF pair is refused despite being one grapheme cluster")
    func crlfIsRefused() {
        // `"\r\n"` is a single cluster of two scalars under UAX #29 rule GB3,
        // so a single-scalar guard passes both through. Ordinary input from a
        // Windows file, an HTTP header, or a CRLF checkout.
        #expect(controlCells("a\r\nb") == 0)
    }

    @Test("combining marks still merge onto the previous cell")
    func combiningMarksStillMerge() {
        // The zero-width merge exists for combining marks, and must survive.
        // "e" + U+0301 renders as one cell holding "é".
        var buffer = CellBuffer(width: 8, height: 1)
        buffer.write("e\u{301}x", x: 0, y: 0, style: plain)
        #expect(buffer[0, 0].character == "e\u{301}",
                "combining acute must still compose onto its base")
        #expect(buffer[1, 0].character == "x",
                "the following glyph keeps its own cell")
    }

    @Test("tab and newline are refused like any other control")
    func tabAndNewlineRefused() {
        // Layout owns line breaking and indentation; a literal tab or newline
        // stored in a cell would bypass both and desynchronise the compositor's
        // idea of what occupies each column.
        #expect(controlCells("a\tb") == 0)
        #expect(controlCells("a\nb") == 0)
    }

    @Test("ordinary text is untouched")
    func ordinaryTextUnaffected() {
        #expect(rendered("hello") == "hello")
        #expect(rendered("héllo") == "héllo")
        // A wide glyph claims two cells, the second a spacer — so reading the
        // row cell by cell yields "日 本". Assert the glyphs survived rather
        // than re-describing the buffer's padding here.
        #expect(rendered("日本").contains("日"))
        #expect(rendered("日本").contains("本"))
    }
}

@Suite("Control characters are refused at every writer")
@MainActor
struct ControlCharacterWriterCoverageTests {

    @Test("the subscript setter refuses a control character")
    func subscriptSetterRefuses() {
        // The single choke point every writer passes through — the same place
        // clip enforcement lives, so no future caller can forget to filter.
        var buffer = CellBuffer(width: 4, height: 1)
        buffer[0, 0] = Cell(character: "\u{1B}", style: plain)
        #expect(buffer[0, 0].character != "\u{1B}",
                "a control character must not be storable in a cell")
    }

    @Test("styled spans refuse control characters too")
    func spansRefuse() {
        var buffer = CellBuffer(width: 12, height: 2)
        buffer.writeSpans(
            [TextSpan("ab\u{1B}[2Jc")],
            x: 0, y: 0, maxWidth: 12, maxHeight: 2, baseStyle: plain
        )
        #expect(controlCellCount(buffer, width: 12, height: 2) == 0,
                "writeSpans must sanitize on the same terms as write")
    }

    @Test("fill refuses a control character")
    func fillRefuses() {
        var buffer = CellBuffer(width: 4, height: 1)
        buffer.fill(Rect(x: 0, y: 0, width: 4, height: 1),
                    character: "\u{1B}", style: plain)
        #expect(controlCellCount(buffer, width: 4) == 0,
                "fill must not paint control characters across a region")
    }
}


