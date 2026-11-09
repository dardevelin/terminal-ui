import Testing
@testable import TerminalUI

// Shared word-wrap utility (`TextLayout.wrapWords`). Source of truth
// for any TerminalUI component that lays out long text — PromptInput
// (today), Text primitive (next), TextArea + custom views (future).
//
// Contract mirrors SwiftUI's default wrap (CoreText
// kCTLineBreakByWordWrapping) and Apple HIG's prescription for
// "text view" content: prefer whitespace boundaries; long words
// (URLs, identifiers) hard-break at character level so they don't
// disappear off-screen.

@Suite("TextLayout — word-aware wrap")
@MainActor
struct TextLayoutTests {

    @Test("ASCII sentence wraps at word boundaries, never mid-word")
    func sentenceWrapsAtWordBoundaries() {
        let sentence = "type a very long line and see if it will properly wrap"
        let chunks = TextLayout.wrapWords(sentence, width: 20)
        // No two consecutive chunks should reconstruct a contiguous
        // word from the source. If chunks[i] ends in a letter and
        // chunks[i+1] starts with a letter, the pair "lastChar
        // firstChar" must NOT appear in the source — otherwise we
        // split a word.
        for i in 0..<chunks.count - 1 {
            let a = chunks[i]
            let b = chunks[i + 1]
            if let last = a.last, let first = b.first,
               last.isLetter, first.isLetter
            {
                let pair = "\(last)\(first)"
                #expect(!sentence.contains(pair),
                        "split word at boundary: chunks[\(i)]=\(a), chunks[\(i+1)]=\(b)")
            }
        }
    }

    @Test("re-joining wrapped chunks reproduces the source modulo dropped boundary spaces")
    func wrappingIsLossless() {
        let sentence = "type a very long line and see if it will properly wrap and do the right thing"
        let chunks = TextLayout.wrapWords(sentence, width: 20)
        for chunk in chunks {
            #expect(chunk.count <= 20, "chunk over width: \(chunk) (\(chunk.count) > 20)")
        }
        // Glue chunks with single spaces where a boundary space was
        // dropped. Resulting non-space char sequence must match.
        let nonSpaceSrc = sentence.filter { $0 != " " }
        let nonSpaceJoined = chunks.joined().filter { $0 != " " }
        #expect(nonSpaceSrc == nonSpaceJoined,
                "char sequence diverged: \(nonSpaceJoined.debugDescription)")
    }

    @Test("a single word longer than width hard-breaks at character level")
    func longWordHardBreaks() {
        let url = "https://example.com/very/long/path/that/exceeds/wrap/width"
        let chunks = TextLayout.wrapWords(url, width: 20)
        for chunk in chunks { #expect(chunk.count <= 20) }
        #expect(chunks.joined() == url, "spaceless input must reassemble exactly")
        #expect(chunks.count >= 2, "long URL must wrap into multiple chunks")
    }

    @Test("short input that fits returns one chunk unchanged")
    func shortInputOneChunk() {
        let s = "hello world"
        #expect(TextLayout.wrapWords(s, width: 20) == [s])
    }

    @Test("empty input yields one empty chunk so the row stays navigable")
    func emptyInputOneEmptyChunk() {
        #expect(TextLayout.wrapWords("", width: 20) == [""])
    }

    @Test("zero or negative width is treated as no-wrap (single-chunk)")
    func zeroWidthNoWrap() {
        let s = "abc def"
        #expect(TextLayout.wrapWords(s, width: 0) == [s])
        #expect(TextLayout.wrapWords(s, width: -5) == [s])
    }

    @Test("multi-space runs are preserved as runs across wrap boundaries")
    func multipleSpacesPreserved() {
        let s = "a  b  c  d  e  f  g  h"
        let chunks = TextLayout.wrapWords(s, width: 8)
        for chunk in chunks { #expect(chunk.count <= 8) }
        // Non-space char sequence must reproduce the source.
        let nonSpaceSrc = s.filter { $0 != " " }
        let nonSpaceOut = chunks.joined().filter { $0 != " " }
        #expect(nonSpaceSrc == nonSpaceOut)
    }

    @Test("a word that exactly equals width fits on one line")
    func exactWidthWord() {
        let chunks = TextLayout.wrapWords("hello", width: 5)
        #expect(chunks == ["hello"])
    }

    @Test("two short words fitting exactly on one line do not wrap")
    func twoWordsFitExactly() {
        let chunks = TextLayout.wrapWords("ab cd", width: 5)
        #expect(chunks == ["ab cd"])
    }

    @Test("regression: width-31 wrap of long sentence does not split 'if'")
    func width31DoesNotSplitIf() {
        let s = "type a very long line and see if it will properly wrap and do the right thing and be nice"
        let chunks = TextLayout.wrapWords(s, width: 31)
        // The source contains "see if " — chunks must not split it.
        for (i, chunk) in chunks.enumerated() where i > 0 {
            let prev = chunks[i - 1]
            if let last = prev.last, let first = chunk.first,
               last.isLetter, first.isLetter
            {
                let pair = "\(last)\(first)"
                #expect(!s.contains(pair),
                        "split word at chunks[\(i-1)]='\(prev)' / chunks[\(i)]='\(chunk)' — pair '\(pair)' contiguous in source")
            }
        }
    }
}

// An editor needs to know where each wrapped row sits in its line, not only
// what it shows: the spaces a wrap drops lie between two rows, and every
// column after them belongs to a character further along than the rows'
// lengths add up to.

@Suite("WrappedLine — the caret positions a wrapped line maps to cells")
struct WrappedLineTests {

    @Test func rowsSkipTheWhitespaceAWrapDrops() {
        let line = WrappedLine("alpha beta  gamma", width: 10)
        #expect(line.rows == [0..<10, 12..<17])
        #expect(line.rows.indices.map(line.text(ofRow:)) == TextLayout.wrapWords("alpha beta  gamma", width: 10))
    }

    @Test func aCaretInDroppedWhitespaceIsDrawnWhereTheNextRowStarts() {
        let line = WrappedLine("alpha beta  gamma", width: 10)
        for index in 10...12 {
            #expect(line.caret(at: index) == WrappedLine.Caret(row: 1, column: 0, offset: 0), "\(index)")
        }
        #expect(line.caret(at: 13) == WrappedLine.Caret(row: 1, column: 1, offset: 1))
        #expect(line.caret(at: 17) == WrappedLine.Caret(row: 1, column: 5, offset: 5), "the line's end")
    }

    @Test func aColumnIsTheGlyphDrawnOverIt() {
        // 中 0–1, 文 2–3, a 4
        let line = WrappedLine("中文a", width: 10)
        #expect((0...5).map { line.index(row: 0, column: $0) } == [0, 0, 1, 1, 2, 3])
        #expect(line.caret(at: 2).column == 4)
    }

    @Test func pastTheEndOfAWrappedRowIsItsLastCharacter() {
        let line = WrappedLine("alpha beta gamma", width: 10)
        #expect(line.index(row: 0, column: 40) == 9, "the row's end is drawn on the next row")
        #expect(line.index(row: 1, column: 40) == 16, "the line's end")
    }

    @Test func whitespaceDroppedAtTheLinesEndIsDrawnAtTheLastRowsEnd() {
        let line = WrappedLine("hello world  ", width: 11)
        #expect(line.rows == [0..<11])
        #expect(line.caret(at: 13) == WrappedLine.Caret(row: 0, column: 11, offset: 11))
        #expect(line.index(row: 0, column: 40) == 13, "past the end is the line's end")
    }
}
