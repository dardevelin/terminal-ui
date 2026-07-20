import Testing
@testable import TerminalUI

// TextLayout and LineBreakMode used `String.count`
// (grapheme count), but CellBuffer.write uses `displayWidth` (cell
// count). CJK + emoji content wraps and truncates at the wrong
// column because Character.count != cell width.
//
// These tests pin the fixed contract: wrap and truncate respect cell
// width, not grapheme count.

@Suite("Unicode width — wrap + truncate respect display cells")
struct UnicodeWidthLayoutTests {

    @Test("wrapWords breaks CJK at cell width, not grapheme count")
    func wrapCJKAtCellBoundary() {
        // Each CJK ideograph is 2 cells. "中文" = 2 chars but 4 cells.
        // At width=4, "中文" fits on one line. At width=3, "中" alone
        // (2 cells) fits but "中文" (4 cells) does not — must wrap.
        let chunks = TextLayout.wrapWords("中文", width: 3)
        #expect(chunks.count >= 2,
                "CJK pair should wrap at width 3 (each char is 2 cells); got \(chunks)")
    }

    @Test("wrapWords keeps a 2-cell emoji on one line at width 2")
    func emojiFitsAtWidth2() {
        // "🎯" is 1 grapheme but 2 cells. At width 2 it fits; at
        // width 1 it must NOT be split mid-grapheme — should wrap
        // (or stay as-is on a single chunk; just don't crash).
        let chunks = TextLayout.wrapWords("🎯", width: 2)
        #expect(chunks.first == "🎯",
                "emoji at width=2 should fit on one chunk; got \(chunks)")
    }

    @Test("byTruncatingTail truncates at cell width, not grapheme count")
    func truncateTailAtCellBoundary() {
        // "héllo🎯wörld" = 11 graphemes BUT 12 cells (emoji = 2).
        // Truncating to 8 cells must include ellipsis at the right
        // CELL column. At grapheme-count truncation it would stop at
        // grapheme index 7 = "héllo🎯w" which is 8 cells without
        // ellipsis room.
        // Pre-fix: String.count truncation gives wrong column.
        // Post-fix: displayWidth truncation aligns with cell column.
        let result = LineBreakMode.byTruncatingTail.apply(to: "héllo🎯wörld", width: 8)
        #expect(result.displayWidth <= 8,
                "truncated string must fit in 8 cells; got width=\(result.displayWidth) for \(result.debugDescription)")
    }

    @Test("byTruncatingTail with all-CJK input clamps to cell width")
    func truncateCJKAtCellBoundary() {
        // "中国语言文化" = 6 graphemes, 12 cells.
        // Truncate to width 6: should fit 2 chars + ellipsis (= 5 cells)
        // or 3 chars + nothing (= 6 cells) — either way, displayWidth ≤ 6.
        let result = LineBreakMode.byTruncatingTail.apply(to: "中国语言文化", width: 6)
        #expect(result.displayWidth <= 6,
                "CJK truncation to 6 cells must produce a string ≤ 6 cells; got width=\(result.displayWidth) for \(result.debugDescription)")
    }
}
