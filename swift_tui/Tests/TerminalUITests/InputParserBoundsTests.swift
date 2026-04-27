import Testing
@testable import TerminalUI

// Defensive parser hardening — the same nil-tolerance pattern that
// fixed bracketed-paste collection (`collectBracketedPaste`) needs to
// extend to every multi-byte sequence the InputParser collects from
// a live ByteSource. raw-mode VTIME=1 timeouts return nil mid-stream;
// short sequences are less commonly split than long pastes, but not
// never — tmux/screen multiplexing and mouse-motion bursts both
// produce multi-byte runs that can straddle a read() boundary.
//
// Two functions read directly from a `ByteSource` to accumulate a
// known-length tail after a start marker:
//
//   * `parseSgrMouse` — `Cb;Cx;Cy[Mm]` after `ESC[<`.
//   * `parseExtendedCsi` — variable-length CSI params terminated by
//     a final byte (`A`-`Z`, `~`, or `u`).
//
// `parseTildeKey` and `parseKittyKey` take pre-collected `[UInt8]`
// params and don't read from a ByteSource themselves, so they
// inherit `parseExtendedCsi`'s collection robustness without needing
// their own retry logic.
//
// The fixture pattern (transient-nil between chunks) reuses the
// `ChunkedByteSource` shape from PasteCollectionTests — copied
// inline here so this suite is self-contained.

/// Simulates a stdin source that hands out bytes in chunks separated
/// by transient nils. Mirrors the raw-mode VTIME=1 behaviour where a
/// `read(2)` may return 0 bytes mid-sequence.
private struct ChunkedSource: ByteSource {
    var chunks: [[UInt8]]
    var pos: Int = 0
    var nilPending: Bool = false

    init(_ chunks: [[UInt8]]) {
        self.chunks = chunks
    }

    mutating func readByte() -> UInt8? {
        if nilPending {
            nilPending = false
            return nil
        }
        guard !chunks.isEmpty else { return nil }
        let chunk = chunks[0]
        if pos < chunk.count {
            let byte = chunk[pos]
            pos += 1
            return byte
        }
        chunks.removeFirst()
        pos = 0
        if !chunks.isEmpty {
            nilPending = true
            return nil
        }
        return nil
    }
}

@Suite("InputParser — multi-byte sequences survive transient nils")
@MainActor
struct InputParserBoundsTests {

    // MARK: - parseSgrMouse

    @Test("SGR mouse sequence fully contained in one chunk parses")
    func sgrMouseSingleChunk() {
        // ESC [ < 0 ; 5 ; 7 M  — left-button press at (col=4, row=6) (0-indexed).
        let bytes: [UInt8] = [
            0x1B, 0x5B, 0x3C,                      // ESC [ <
            0x30, 0x3B, 0x35, 0x3B, 0x37, 0x4D,    // "0;5;7M"
        ]
        var source = ArrayByteSource(bytes)
        let event = InputParser.parseEvent(from: &source)
        guard case .mouse(let mouse) = event else {
            Issue.record("expected .mouse event, got \(String(describing: event))")
            return
        }
        #expect(mouse.x == 4)
        #expect(mouse.y == 6)
    }

    @Test("SGR mouse sequence split across a transient nil parses correctly")
    func sgrMouseSplitAcrossNil() {
        // Same sequence as above but split between the second `;` and the
        // row digit, so a transient nil lands inside the params loop —
        // exactly the bug shape we're hardening against.
        let chunk1: [UInt8] = [
            0x1B, 0x5B, 0x3C,           // ESC [ <
            0x30, 0x3B, 0x35, 0x3B,     // "0;5;"
        ]
        let chunk2: [UInt8] = [
            0x37, 0x4D,                 // "7M"
        ]
        var source = ChunkedSource([chunk1, chunk2])
        let event = InputParser.parseEvent(from: &source)
        guard case .mouse(let mouse) = event else {
            Issue.record("expected .mouse event, got \(String(describing: event))")
            return
        }
        #expect(mouse.x == 4,
                "split SGR mouse coords must reassemble: x expected 4, got \(mouse.x)")
        #expect(mouse.y == 6,
                "split SGR mouse coords must reassemble: y expected 6, got \(mouse.y)")
    }

    @Test("SGR mouse sequence split BEFORE final byte parses correctly")
    func sgrMouseSplitBeforeFinalByte() {
        // Edge case: split immediately before the `M` final byte. The
        // byte-collection loop must keep retrying after a nil to read
        // the final byte; otherwise it returns the .unknown fallback.
        let chunk1: [UInt8] = [
            0x1B, 0x5B, 0x3C,
            0x30, 0x3B, 0x35, 0x3B, 0x37,    // "0;5;7"
        ]
        let chunk2: [UInt8] = [0x4D]          // "M"
        var source = ChunkedSource([chunk1, chunk2])
        let event = InputParser.parseEvent(from: &source)
        guard case .mouse = event else {
            Issue.record("expected .mouse event, got \(String(describing: event))")
            return
        }
    }

    // MARK: - parseExtendedCsi

    @Test("Tilde-key CSI sequence (Home) split across a nil parses correctly")
    func extendedCsiTildeSplit() {
        // ESC [ 1 ~ — Home key. Split between the `1` and the `~`.
        let chunk1: [UInt8] = [
            0x1B, 0x5B, 0x31,   // ESC [ 1
        ]
        let chunk2: [UInt8] = [
            0x7E,               // ~
        ]
        var source = ChunkedSource([chunk1, chunk2])
        let event = InputParser.parseEvent(from: &source)
        guard case .key(let key) = event else {
            Issue.record("expected .key event for Home, got \(String(describing: event))")
            return
        }
        #expect(key.key == .home)
    }

    @Test("Modified arrow CSI sequence split mid-params parses correctly")
    func extendedCsiArrowSplit() {
        // ESC [ 1 ; 5 A — Ctrl+Up (kitty/xterm modifier encoding). Split
        // between the `;` and the modifier digit.
        let chunk1: [UInt8] = [
            0x1B, 0x5B, 0x31, 0x3B,    // ESC [ 1 ;
        ]
        let chunk2: [UInt8] = [
            0x35, 0x41,                // 5 A
        ]
        var source = ChunkedSource([chunk1, chunk2])
        let event = InputParser.parseEvent(from: &source)
        guard case .key(let key) = event else {
            Issue.record("expected .key event for Ctrl+Up, got \(String(describing: event))")
            return
        }
        #expect(key.key == .up)
        #expect(key.modifiers.contains(.ctrl))
    }

    @Test("Kitty keyboard CSI sequence split mid-params parses correctly")
    func extendedCsiKittySplit() {
        // ESC [ 1 3 u — kitty encoding for Enter. Split between `1` and `3`.
        let chunk1: [UInt8] = [
            0x1B, 0x5B, 0x31,    // ESC [ 1
        ]
        let chunk2: [UInt8] = [
            0x33, 0x75,          // 3 u
        ]
        var source = ChunkedSource([chunk1, chunk2])
        let event = InputParser.parseEvent(from: &source)
        guard case .key(let key) = event else {
            Issue.record("expected .key event for Enter, got \(String(describing: event))")
            return
        }
        #expect(key.key == .enter)
    }
}
