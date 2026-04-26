import Testing
@testable import TerminalUI

// xterm bracketed-paste protocol (DEC private mode 2004): when the
// mode is active, paste content is wrapped in ESC[200~ ... ESC[201~.
// Without bracketing, paste is indistinguishable from extremely
// fast keyboard input. With bracketing, the parser emits a single
// `TerminalEvent.paste(String)` carrying the unparsed bytes — control
// sequences inside the wrapper are NOT interpreted as keys.
//
// Spec: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
//   "Bracketed Paste Mode" (1004 / 2004).

@Suite("InputParser — bracketed paste")
struct BracketedPasteParsingTests {

    @Test("simple paste between markers emits one paste event")
    func simplePaste() {
        let bytes: [UInt8] = bracketedPaste("hello\nworld")
        var source = ArrayByteSource(bytes)
        let event = InputParser.parseEvent(from: &source)
        guard case .paste(let payload) = event else {
            Issue.record("expected .paste, got \(String(describing: event))")
            return
        }
        #expect(payload == "hello\nworld",
                "payload must be the bytes between the markers, decoded as UTF-8")
    }

    @Test("empty paste emits an empty-string paste event")
    func emptyPaste() {
        var source = ArrayByteSource(bracketedPaste(""))
        let event = InputParser.parseEvent(from: &source)
        guard case .paste(let payload) = event else {
            Issue.record("expected .paste, got \(String(describing: event))")
            return
        }
        #expect(payload == "",
                "ESC[200~ESC[201~ with no content between is still a valid paste")
    }

    @Test("paste with embedded ESC bytes treats them as paste content")
    func pasteWithEmbeddedEscape() {
        // The whole point of bracketed paste: a control sequence INSIDE
        // the wrapper is plain text. If the parser interpreted the inner
        // ESC[A as an arrow-up key, paste of source code containing
        // escape characters would corrupt the user's input.
        let inner = "\u{1B}[A"  // would be Up arrow if interpreted
        var source = ArrayByteSource(bracketedPaste(inner))
        let event = InputParser.parseEvent(from: &source)
        guard case .paste(let payload) = event else {
            Issue.record("expected .paste, got \(String(describing: event))")
            return
        }
        #expect(payload == inner,
                "embedded escape bytes must arrive verbatim in the paste payload")
    }

    @Test("paste content with multibyte UTF-8 round-trips intact")
    func unicodePaste() {
        let inner = "héllo 🎯 wörld"
        var source = ArrayByteSource(bracketedPaste(inner))
        let event = InputParser.parseEvent(from: &source)
        guard case .paste(let payload) = event else {
            Issue.record("expected .paste, got \(String(describing: event))")
            return
        }
        #expect(payload == inner,
                "multibyte UTF-8 must decode correctly inside paste payload")
    }

    @Test("text without paste markers parses as ordinary keys, not paste")
    func noMarkersIsRegularInput() {
        // Bytes that look like paste content but aren't bracketed must
        // arrive as individual character key events — bracketed paste
        // is opt-in via the wrapper, never inferred from content.
        var source = ArrayByteSource([UInt8(ascii: "a")])
        let event = InputParser.parseEvent(from: &source)
        guard case .key(let key) = event,
              case .character(let ch) = key.key else {
            Issue.record("expected .key(.character), got \(String(describing: event))")
            return
        }
        #expect(ch == "a")
    }
}

// Bracketed-paste markers per xterm ctlseqs:
// start: ESC [ 2 0 0 ~
// end:   ESC [ 2 0 1 ~
private func bracketedPaste(_ content: String) -> [UInt8] {
    var bytes: [UInt8] = [0x1B, UInt8(ascii: "["), UInt8(ascii: "2"),
                          UInt8(ascii: "0"), UInt8(ascii: "0"), UInt8(ascii: "~")]
    bytes.append(contentsOf: Array(content.utf8))
    bytes.append(contentsOf: [0x1B, UInt8(ascii: "["), UInt8(ascii: "2"),
                              UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "~")])
    return bytes
}
