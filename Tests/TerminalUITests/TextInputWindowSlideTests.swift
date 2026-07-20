import Testing
@testable import TerminalUI

// HYP-218 — TextInput's `windowedSlice` must "scroll only when the
// cursor would clip" instead of recentring the cursor mid-buffer
// every frame. Pre-HYP-208 this worked because the window always
// pinned to the tail; HYP-208's new model centres aggressively which
// breaks the editing flow when the user arrows left mid-buffer.
//
// The assertions below pin the four behavioural quadrants:
//
//   1. Cursor at end (typing case)         → window pins to tail.
//   2. Cursor moves left within window     → window stays put.
//   3. Cursor reaches LEFT edge + Left     → window slides left by 1.
//   4. Cursor reaches RIGHT edge + Right   → window slides right by 1.
//
// These exercise `windowedSlice` directly via its new
// `windowStart` parameter (sentinel `-1` = uninitialised).

@Suite("TextInput — windowedSlice slides only on edge-clip")
@MainActor
struct TextInputWindowSlideTests {

    @Test("Cursor at end pins window to tail (initial render / typing)")
    func cursorAtEndPinsToTail() {
        // 30-char value, 10-cell room, cursor at end (=30), uninitialised window.
        // The cursor sits ONE PAST the last cell — legacy "after-tail
        // cursor" rendering that `appendWithCursor` expects (it draws
        // the cursor glyph after the visible content).
        let value = String(repeating: "x", count: 27) + "abc"
        let result = TextInput.windowedSlice(value: value, cursor: 30, room: 10, windowStart: -1)
        #expect(result.cursorOffset == 10,
                "cursor sits one past the rightmost cell when at end (after-tail rendering)")
        // The visible window should cover the last 10 chars: "xxxxxxxabc"
        #expect(result.visible.hasSuffix("abc"))
        #expect(result.visible.count == 10)
        #expect(result.windowStart == 20, "window anchored to value.count - room = 20")
    }

    @Test("Cursor moves left within window — windowStart unchanged")
    func leftWithinWindowDoesNotSlide() {
        // Value 30 chars, window of 10 chars, currently anchored at 20.
        // Cursor moves from 30 down to 25 (still in window [20..30)).
        let value = String(repeating: "x", count: 27) + "abc"
        let result = TextInput.windowedSlice(value: value, cursor: 25, room: 10, windowStart: 20)
        #expect(result.windowStart == 20,
                "cursor still inside [20..30) → window doesn't slide; got \(result.windowStart)")
        #expect(result.cursorOffset == 5, "cursor sits at offset 5 within window")
    }

    @Test("Cursor reaches LEFT edge + further Left slides window left by 1")
    func leftEdgeSlidesWindowLeft() {
        // Window anchored at 20. Cursor moves to 19 — would be one before
        // the window's start. `windowedSlice` should slide windowStart to 19.
        let value = String(repeating: "x", count: 30)
        let result = TextInput.windowedSlice(value: value, cursor: 19, room: 10, windowStart: 20)
        #expect(result.windowStart == 19, "windowStart shifts left to follow cursor")
        #expect(result.cursorOffset == 0, "cursor lands at offset 0 (left edge of new window)")
    }

    @Test("Cursor reaches RIGHT edge + further Right slides window right by 1")
    func rightEdgeSlidesWindowRight() {
        // Window anchored at 5. Cursor at 14 (= start + room - 1) is at the
        // rightmost CELL of the window. Moving cursor to 15 (one past)
        // should slide windowStart to 6 so cursor lands at offset 9.
        let value = String(repeating: "x", count: 30)
        let result = TextInput.windowedSlice(value: value, cursor: 15, room: 10, windowStart: 5)
        #expect(result.windowStart == 6, "windowStart shifts right by 1; got \(result.windowStart)")
        #expect(result.cursorOffset == 9, "cursor lands at right edge of new window")
    }

    @Test("Cursor jump (via Home) snaps window to start")
    func cursorJumpToStartSnapsWindow() {
        // Window at 20. Cursor jumps to 0 (Home). The window MUST follow
        // because cursor is now far before windowStart. Per the
        // "clip-left → slide" rule, windowStart becomes cursor=0.
        let value = String(repeating: "x", count: 30)
        let result = TextInput.windowedSlice(value: value, cursor: 0, room: 10, windowStart: 20)
        #expect(result.windowStart == 0)
        #expect(result.cursorOffset == 0)
    }

    @Test("Cursor jump (via End) snaps window to tail")
    func cursorJumpToEndSnapsWindowToTail() {
        let value = String(repeating: "x", count: 30)
        // Window at 0. End → cursor=30, far past the right edge. Slide to tail.
        let result = TextInput.windowedSlice(value: value, cursor: 30, room: 10, windowStart: 0)
        #expect(result.windowStart == 20, "End jump → windowStart = value.count - room")
        #expect(result.cursorOffset == 10, "cursor sits one past last cell (legacy 'after-tail' rendering)")
    }

    @Test("Value fits in room — windowStart stays 0, cursor untouched")
    func shortValueNoWindow() {
        let result = TextInput.windowedSlice(value: "hi", cursor: 2, room: 10, windowStart: -1)
        #expect(result.windowStart == 0, "short value → window starts at 0")
        #expect(result.cursorOffset == 2, "cursor offset is the original cursor")
        #expect(result.visible == "hi")
    }
}
