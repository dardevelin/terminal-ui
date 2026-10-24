import Testing
@testable import TerminalUI

// Drives InputParser's state machine through ArrayByteSource with canned
// byte sequences. ESC = 0x1B, CR = 0x0D, TAB = 0x09, DEL = 0x7F.

@Suite("InputParser — ASCII & control")
struct InputParserASCIITests {

    @Test("plain ASCII character")
    func plainASCII() {
        let event = parse([0x61])
        expectKey(event, .character("a"))
    }

    @Test("Ctrl+key maps to lowercase letter with ctrl modifier")
    func ctrlKey() {
        // Ctrl+C = 0x03
        let event = parse([0x03])
        expectKey(event, .character("c"), modifiers: .ctrl)
    }

    @Test("Enter (CR)")
    func enter() {
        expectKey(parse([0x0D]), .enter)
    }

    @Test("Tab")
    func tab() {
        expectKey(parse([0x09]), .tab)
    }

    @Test("Backspace (Ctrl+H)")
    func backspaceCtrlH() {
        expectKey(parse([0x08]), .backspace)
    }

    @Test("DEL (0x7F) maps to backspace")
    func deletemapsToBackspace() {
        expectKey(parse([0x7F]), .backspace)
    }

    @Test("ESC alone with no follow byte")
    func escAlone() {
        expectKey(parse([0x1B]), .escape)
    }

    @Test("empty source returns nil")
    func emptySource() {
        var source = ArrayByteSource([])
        #expect(InputParser.parseEvent(from: &source) == nil)
    }
}

@Suite("InputParser — Arrow & navigation keys (CSI)")
struct InputParserCSITests {

    @Test("Up arrow")
    func up() { expectKey(parse([0x1B, 0x5B, 0x41]), .up) }

    @Test("Down arrow")
    func down() { expectKey(parse([0x1B, 0x5B, 0x42]), .down) }

    @Test("Right arrow")
    func right() { expectKey(parse([0x1B, 0x5B, 0x43]), .right) }

    @Test("Left arrow")
    func left() { expectKey(parse([0x1B, 0x5B, 0x44]), .left) }

    @Test("Home")
    func home() { expectKey(parse([0x1B, 0x5B, 0x48]), .home) }

    @Test("End")
    func end() { expectKey(parse([0x1B, 0x5B, 0x46]), .end) }

    @Test("Shift+Tab (CSI Z)")
    func shiftTab() {
        expectKey(parse([0x1B, 0x5B, 0x5A]), .tab, modifiers: .shift)
    }

    @Test("Ctrl+Up (CSI 1;5 A)")
    func ctrlUp() {
        // ESC [ 1 ; 5 A
        expectKey(parse([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41]), .up, modifiers: .ctrl)
    }

    @Test("Shift+Down (CSI 1;2 B)")
    func shiftDown() {
        expectKey(parse([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x42]), .down, modifiers: .shift)
    }

    @Test("Alt+Right (CSI 1;3 C)")
    func altRight() {
        expectKey(parse([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x43]), .right, modifiers: .alt)
    }

    @Test("Ctrl+Shift+Left (CSI 1;6 D)")
    func ctrlShiftLeft() {
        expectKey(parse([0x1B, 0x5B, 0x31, 0x3B, 0x36, 0x44]), .left, modifiers: [.shift, .ctrl])
    }
}

@Suite("InputParser — Tilde keys & F-keys")
struct InputParserTildeTests {

    @Test("Delete (CSI 3~)")
    func delete() {
        expectKey(parse([0x1B, 0x5B, 0x33, 0x7E]), .delete)
    }

    @Test("PageUp (CSI 5~)")
    func pageUp() {
        expectKey(parse([0x1B, 0x5B, 0x35, 0x7E]), .pageUp)
    }

    @Test("PageDown (CSI 6~)")
    func pageDown() {
        expectKey(parse([0x1B, 0x5B, 0x36, 0x7E]), .pageDown)
    }

    @Test("F5 (CSI 15~)")
    func f5() {
        expectKey(parse([0x1B, 0x5B, 0x31, 0x35, 0x7E]), .f(5))
    }

    @Test("F12 (CSI 24~)")
    func f12() {
        expectKey(parse([0x1B, 0x5B, 0x32, 0x34, 0x7E]), .f(12))
    }

    @Test("F1 via SS3 (ESC O P)")
    func f1SS3() {
        expectKey(parse([0x1B, 0x4F, 0x50]), .f(1))
    }

    @Test("F2 via SS3 (ESC O Q)")
    func f2SS3() {
        expectKey(parse([0x1B, 0x4F, 0x51]), .f(2))
    }

    @Test("F3 via SS3 (ESC O R)")
    func f3SS3() {
        expectKey(parse([0x1B, 0x4F, 0x52]), .f(3))
    }

    @Test("F4 via SS3 (ESC O S)")
    func f4SS3() {
        expectKey(parse([0x1B, 0x4F, 0x53]), .f(4))
    }
}

@Suite("InputParser — Alt & kitty protocol")
struct InputParserAltKittyTests {

    @Test("Alt+Enter (ESC CR)")
    func altEnter() {
        expectKey(parse([0x1B, 0x0D]), .enter, modifiers: .alt)
    }

    @Test("Alt+a (ESC 'a')")
    func altA() {
        expectKey(parse([0x1B, 0x61]), .character("a"), modifiers: .alt)
    }

    @Test("Kitty: Shift+Enter (ESC [ 13 ; 2 u)")
    func kittyShiftEnter() {
        expectKey(parse([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75]),
                  .enter, modifiers: .shift)
    }

    @Test("Kitty: Ctrl+Enter (ESC [ 13 ; 5 u)")
    func kittyCtrlEnter() {
        expectKey(parse([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x35, 0x75]),
                  .enter, modifiers: .ctrl)
    }

    @Test("Kitty: plain 'a' keycode 97 (ESC [ 97 ; 1 u)")
    func kittyPlainA() {
        expectKey(parse([0x1B, 0x5B, 0x39, 0x37, 0x3B, 0x31, 0x75]),
                  .character("a"))
    }

    @Test("Kitty: Escape via ESC [ 27 ; 1 u")
    func kittyEscape() {
        expectKey(parse([0x1B, 0x5B, 0x32, 0x37, 0x3B, 0x31, 0x75]), .escape)
    }

    @Test("Kitty: release event (type 3) is ignored")
    func kittyReleaseIgnored() {
        // ESC [ 97 ; 1 ; 3 u
        let event = parse([0x1B, 0x5B, 0x39, 0x37, 0x3B, 0x31, 0x3B, 0x33, 0x75])
        // Parser returns .key(.unknown([])) for release; assert it's not a normal character
        guard case .key(let k) = event else {
            Issue.record("expected .key event")
            return
        }
        if case .character = k.key {
            Issue.record("release should not produce .character")
        }
    }
}

@Suite("InputParser — SGR 1006 mouse")
struct InputParserMouseTests {

    @Test("left-button press at (10, 5)")
    func leftPress() {
        // ESC [ < 0 ; 11 ; 6 M  (1-indexed → (10, 5) 0-indexed)
        let event = parse([0x1B, 0x5B, 0x3C, 0x30, 0x3B, 0x31, 0x31, 0x3B, 0x36, 0x4D])
        expectMouse(event, kind: .press(.left), x: 10, y: 5)
    }

    @Test("left-button release at (10, 5)")
    func leftRelease() {
        // ESC [ < 0 ; 11 ; 6 m
        let event = parse([0x1B, 0x5B, 0x3C, 0x30, 0x3B, 0x31, 0x31, 0x3B, 0x36, 0x6D])
        expectMouse(event, kind: .release(.left), x: 10, y: 5)
    }

    @Test("middle-button press")
    func middlePress() {
        // button code 1 = middle
        let event = parse([0x1B, 0x5B, 0x3C, 0x31, 0x3B, 0x31, 0x3B, 0x31, 0x4D])
        expectMouse(event, kind: .press(.middle), x: 0, y: 0)
    }

    @Test("right-button press")
    func rightPress() {
        // button code 2 = right
        let event = parse([0x1B, 0x5B, 0x3C, 0x32, 0x3B, 0x31, 0x3B, 0x31, 0x4D])
        expectMouse(event, kind: .press(.right), x: 0, y: 0)
    }

    @Test("scroll up (button code 64)")
    func scrollUp() {
        // 64 | 0 = scrollFlag + buttonNumber 0 = up
        let event = parse([0x1B, 0x5B, 0x3C, 0x36, 0x34, 0x3B, 0x35, 0x3B, 0x35, 0x4D])
        expectMouse(event, kind: .scrollUp, x: 4, y: 4)
    }

    @Test("scroll down (button code 65)")
    func scrollDown() {
        let event = parse([0x1B, 0x5B, 0x3C, 0x36, 0x35, 0x3B, 0x35, 0x3B, 0x35, 0x4D])
        expectMouse(event, kind: .scrollDown, x: 4, y: 4)
    }

    @Test("motion with button (drag)")
    func drag() {
        // motion flag 32 + button 0 = drag left
        let event = parse([0x1B, 0x5B, 0x3C, 0x33, 0x32, 0x3B, 0x31, 0x30, 0x3B, 0x35, 0x4D])
        expectMouse(event, kind: .drag(.left), x: 9, y: 4)
    }

    @Test("motion without button (moved)")
    func moved() {
        // motion + button_number 3 = moved
        let event = parse([0x1B, 0x5B, 0x3C, 0x33, 0x35, 0x3B, 0x31, 0x3B, 0x31, 0x4D])
        expectMouse(event, kind: .moved, x: 0, y: 0)
    }

    @Test("shift-click (button code 4)")
    func shiftClick() {
        // button 0 + shift bit 4 = 4
        let event = parse([0x1B, 0x5B, 0x3C, 0x34, 0x3B, 0x31, 0x3B, 0x31, 0x4D])
        expectMouse(event, kind: .press(.left), x: 0, y: 0, modifiers: .shift)
    }

    // xterm ctlseqs, "Mouse Tracking": wheel buttons 4–7 arrive as codes
    // 64–67 — up, down, left, right. A sideways tick is reported as the
    // shift-wheel terminals already send for horizontal scrolling, until
    // MouseEventKind can grow its own cases in a major release.
    @Test("sideways wheel left (code 66) is shift + wheel up")
    func wheelLeft() {
        expectMouse(parse(Array("\u{1B}[<66;5;5M".utf8)), kind: .scrollUp, x: 4, y: 4, modifiers: .shift)
    }

    @Test("sideways wheel right (code 67) is shift + wheel down")
    func wheelRight() {
        expectMouse(parse(Array("\u{1B}[<67;5;5M".utf8)), kind: .scrollDown, x: 4, y: 4, modifiers: .shift)
    }

    // Buttons 8–11 (back, forward) set bit 128. Read through the two low
    // bits alone they were a left press: the back button clicked.
    @Test("an extra button (code 128) is not a click")
    func extraButton() {
        let event = parse(Array("\u{1B}[<128;5;5M".utf8))
        if case .mouse(let mouse) = event {
            Issue.record("expected no mouse event, got \(mouse)")
        }
    }

    // Coordinates are 1-based on the wire; 0 is not a cell.
    @Test("a zero coordinate is not a cell")
    func zeroCoordinate() {
        let event = parse(Array("\u{1B}[<0;0;5M".utf8))
        if case .mouse(let mouse) = event {
            Issue.record("expected no mouse event, got \(mouse)")
        }
    }

    @Test("the last column and row map to the last cell")
    func lastCell() {
        expectMouse(parse(Array("\u{1B}[<0;80;24M".utf8)), kind: .press(.left), x: 79, y: 23)
    }

    // Only digits and ';' may come between `ESC[<` and the final M/m. A
    // sequence cut off and followed by typing must not swallow keys until
    // a literal M happens along.
    @Test("a sequence broken by another byte ends there")
    func brokenSequence() {
        var source = ArrayByteSource(Array("\u{1B}[<0;5x".utf8) + Array("hi".utf8))
        let first = InputParser.parseEvent(from: &source)
        if case .mouse = first { Issue.record("expected the broken sequence to be no mouse event") }
        let next = InputParser.parseEvent(from: &source)
        expectKey(next, .character("h"))
    }

    @Test("ctrl-click (button code 16)")
    func ctrlClick() {
        let event = parse([0x1B, 0x5B, 0x3C, 0x31, 0x36, 0x3B, 0x31, 0x3B, 0x31, 0x4D])
        expectMouse(event, kind: .press(.left), x: 0, y: 0, modifiers: .ctrl)
    }
}

@Suite("InputParser — UTF-8")
struct InputParserUTF8Tests {

    @Test("2-byte UTF-8: é (U+00E9)")
    func twoByte() {
        expectKey(parse([0xC3, 0xA9]), .character("é"))
    }

    @Test("3-byte UTF-8: ✓ (U+2713)")
    func threeByte() {
        expectKey(parse([0xE2, 0x9C, 0x93]), .character("✓"))
    }

    @Test("4-byte UTF-8: 🎯 (U+1F3AF)")
    func fourByte() {
        expectKey(parse([0xF0, 0x9F, 0x8E, 0xAF]), .character("🎯"))
    }
}

// MARK: - Helpers

private func parse(_ bytes: [UInt8]) -> TerminalEvent? {
    var source = ArrayByteSource(bytes)
    return InputParser.parseEvent(from: &source)
}

private func expectKey(
    _ event: TerminalEvent?,
    _ expectedKey: Key,
    modifiers expectedMods: KeyModifiers = [],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let event else {
        Issue.record("expected event, got nil", sourceLocation: sourceLocation)
        return
    }
    guard case .key(let keyEvent) = event else {
        Issue.record("expected .key, got \(event)", sourceLocation: sourceLocation)
        return
    }
    #expect(keyEvent.key == expectedKey, sourceLocation: sourceLocation)
    #expect(keyEvent.modifiers.rawValue == expectedMods.rawValue, sourceLocation: sourceLocation)
}

private func expectMouse(
    _ event: TerminalEvent?,
    kind expectedKind: MouseEventKind,
    x: Int,
    y: Int,
    modifiers expectedMods: KeyModifiers = [],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let event else {
        Issue.record("expected event, got nil", sourceLocation: sourceLocation)
        return
    }
    guard case .mouse(let mouseEvent) = event else {
        Issue.record("expected .mouse, got \(event)", sourceLocation: sourceLocation)
        return
    }
    #expect(mouseEvent.kind == expectedKind, sourceLocation: sourceLocation)
    #expect(mouseEvent.x == x, sourceLocation: sourceLocation)
    #expect(mouseEvent.y == y, sourceLocation: sourceLocation)
    #expect(mouseEvent.modifiers.rawValue == expectedMods.rawValue, sourceLocation: sourceLocation)
}
