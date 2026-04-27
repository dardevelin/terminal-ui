#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - ASCII Constants
// Reference: ECMA-48, ANSI X3.64

private enum ASCII {
    static let backspace: UInt8 = 8
    static let tab: UInt8 = 9
    static let carriageReturn: UInt8 = 13
    static let escape: UInt8 = 27
    static let delete: UInt8 = 127

    /// Ctrl+A = 0x01 ... Ctrl+Z = 0x1A
    static let ctrlKeyRange: ClosedRange<UInt8> = 1...26
    /// Offset to convert Ctrl byte to lowercase letter: Ctrl+A (1) + 96 = 'a' (97)
    static let ctrlToLowercaseOffset: UInt8 = 96
    /// Printable ASCII range (space through tilde)
    static let printableRange: ClosedRange<Int> = 32...126
}

// MARK: - SGR 1006 Mouse Protocol Bitmasks
// Reference: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html (Mouse Tracking)
//
// Format: CSI < Cb ; Cx ; Cy M (press) or CSI < Cb ; Cx ; Cy m (release)
// Cx, Cy are 1-indexed column/row. Cb is a bitfield:
//
//   Bits 0-1: button number (0=left, 1=middle, 2=right, 3=release/none)
//   Bit 2:    shift
//   Bit 3:    alt (meta)
//   Bit 4:    ctrl
//   Bit 5:    motion (drag or move — set when mouse moves with/without button)
//   Bit 6:    scroll (set for scroll events; bits 0-1 encode direction: 0=up, 1=down)
//
// SGR 1006 replaces X10 encoding which used a single byte per coordinate,
// limiting positions to column 223. SGR uses decimal ASCII parameters with
// no upper limit. The 'm' final byte for release is also a SGR 1006 addition —
// X10 used button=3 to indicate release, losing which button was released.

private enum SGRMouse {
    static let shiftBit = 4
    static let altBit = 8
    static let ctrlBit = 16
    static let motionFlag = 32
    static let scrollFlag = 64
    static let buttonMask = 0x43
    static let buttonNumberMask = 3
}

// MARK: - xterm Modifier Encoding
// Reference: xterm ctlseqs — extended CSI key sequences use a modifier parameter.
// Value = 1 + bitmask, where bitmask = (shift?1:0) + (alt?2:0) + (ctrl?4:0).
//
// The +1 offset is an xterm convention: parameter position 0 means "omitted"
// in CSI sequences, so "no modifier" must encode as 1 to distinguish from
// "parameter not present." Decode by subtracting 1 before checking bits.

private enum XTermModifier {
    static let shiftBit = 1
    static let altBit = 2
    static let ctrlBit = 4
}

// MARK: - Tilde Key Codes
// Reference: xterm — ESC [ N ~ where N identifies the key.
// Gaps in numbering (7-14, 16, 22) are historical: those codes were assigned to
// VT220 keys that modern terminals don't emit.

private enum TildeCode {
    static let home = 1
    static let insert = 2
    static let delete = 3
    static let end = 4
    static let pageUp = 5
    static let pageDown = 6
    static let f5 = 15
    static let f6 = 17
    static let f7 = 18
    static let f8 = 19
    static let f9 = 20
    static let f10 = 21
    static let f11 = 23
    static let f12 = 24
    /// xterm bracketed-paste start: ESC [ 2 0 0 ~ — switches the parser
    /// into "collect bytes until end marker" mode rather than emitting
    /// a key event. The end marker is `bracketedPasteEnd`.
    static let bracketedPasteStart = 200
    static let bracketedPasteEnd = 201
}

// MARK: - Kitty Keyboard Protocol
// Reference: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
//
// A modern replacement for xterm's escape sequences, adopted by kitty, alacritty,
// wezterm, ghostty. Key advantages over xterm:
// - Unambiguous keycodes (no ESC press vs ESC sequence prefix confusion)
// - Key release events (event_type=3)
// - Reliable modifier reporting for all keys
//
// Format: ESC [ keycode ; modifiers u
// Extended: ESC [ keycode ; modifiers ; event_type u
// Modifiers use the same encoding as xterm (value = 1 + bitmask).
// We ignore release events (type=3) because our event model is press-only.

private enum KittyEventType {
    static let press = 1
    static let `repeat` = 2
    static let release = 3
}

// MARK: - UTF-8 Lead Byte Masks
// Reference: RFC 3629
//
// UTF-8 encodes Unicode code points in 1-4 bytes. The lead byte's high bits
// determine how many continuation bytes (10xxxxxx) follow:
//
//   0xxxxxxx — 1 byte  (U+0000..U+007F, ASCII)
//   110xxxxx — 2 bytes (U+0080..U+07FF)
//   1110xxxx — 3 bytes (U+0800..U+FFFF, includes CJK, emoji base)
//   11110xxx — 4 bytes (U+10000..U+10FFFF, includes emoji, symbols)
//
// Detection: mask the lead byte and compare against the pattern.
// Example: byte 0xE2 (11100010) & mask 0xF0 (11110000) = 0xE0 → 3-byte sequence.

private enum UTF8 {
    static let singleByteMask: UInt8 = 0x80
    static let twoByteMask: UInt8 = 0xE0
    static let twoBytePattern: UInt8 = 0xC0
    static let threeByteMask: UInt8 = 0xF0
    static let threeBytePattern: UInt8 = 0xE0
    static let fourByteMask: UInt8 = 0xF8
    static let fourBytePattern: UInt8 = 0xF0
}

/// Parses raw terminal bytes into KeyEvents or MouseEvents.
/// Handles ANSI escape sequences, SGR 1006 mouse protocol, kitty keyboard protocol, and UTF-8.
///
/// The state machine is decoupled from the byte source via `ByteSource`. Runtime
/// callers use the no-arg `readEvent()` / `readKey()` shims, which wrap stdin.
/// Tests drive `parseEvent(from:)` directly with an `ArrayByteSource`.
public enum InputParser {

    public static func readEvent() -> TerminalEvent? {
        var source = StdinByteSource()
        return parseEvent(from: &source)
    }

    public static func readKey() -> KeyEvent? {
        guard let event = readEvent() else { return nil }
        if case .key(let keyEvent) = event { return keyEvent }
        return nil
    }

    /// Drive the parser state machine from an arbitrary byte source.
    /// Returns nil when the source yields no first byte (stdin timeout in raw mode,
    /// or ArrayByteSource exhausted).
    public static func parseEvent(from source: inout some ByteSource) -> TerminalEvent? {
        guard let byte = source.readByte() else { return nil }

        if ASCII.ctrlKeyRange.contains(byte) {
            if byte == ASCII.carriageReturn { return .key(KeyEvent(key: .enter)) }
            if byte == ASCII.tab { return .key(KeyEvent(key: .tab)) }
            if byte == ASCII.backspace { return .key(KeyEvent(key: .backspace)) }
            let char = Character(UnicodeScalar(byte + ASCII.ctrlToLowercaseOffset))
            return .key(KeyEvent(key: .character(char), modifiers: .ctrl))
        }

        if byte == ASCII.escape {
            return parseEscapeSequence(from: &source)
        }

        if byte == ASCII.delete {
            return .key(KeyEvent(key: .backspace))
        }

        let char = parseUtf8Character(firstByte: byte, from: &source)
        return .key(KeyEvent(key: .character(char)))
    }

    // MARK: - Escape Sequences
    //
    // ESC (0x1B) is both a standalone key AND the prefix for all CSI/SS3 sequences.
    // Disambiguation: read the next byte with a short timeout (set by VTIME in raw mode).
    // If read() returns 0, no byte arrived within 100ms — it was a standalone ESC press.
    // If a byte arrives, it identifies the sequence type:
    //   '[' → CSI (Control Sequence Introducer): cursor keys, mouse, function keys
    //   'O' → SS3 (Single Shift 3): F1-F4 on most terminals
    //   other → Alt+key (terminals send ESC followed by the key byte for Alt combos)

    static func parseEscapeSequence(from source: inout some ByteSource) -> TerminalEvent {
        guard let secondByte = source.readByte() else {
            return .key(KeyEvent(key: .escape))
        }

        if secondByte == UInt8(ascii: "[") {
            return parseCsiSequence(from: &source)
        }

        if secondByte == UInt8(ascii: "O") {
            return parseSsSequence(from: &source)
        }

        if secondByte == ASCII.carriageReturn {
            return .key(KeyEvent(key: .enter, modifiers: .alt))
        }

        let char = Character(UnicodeScalar(secondByte))
        return .key(KeyEvent(key: .character(char), modifiers: .alt))
    }

    static func parseCsiSequence(from source: inout some ByteSource) -> TerminalEvent {
        guard let thirdByte = source.readByte() else {
            return .key(KeyEvent(key: .escape))
        }

        // SGR 1006 mouse: ESC [ < Cb ; Cx ; Cy M/m
        if thirdByte == UInt8(ascii: "<") {
            return parseSgrMouse(from: &source)
        }

        switch thirdByte {
        case UInt8(ascii: "A"): return .key(KeyEvent(key: .up))
        case UInt8(ascii: "B"): return .key(KeyEvent(key: .down))
        case UInt8(ascii: "C"): return .key(KeyEvent(key: .right))
        case UInt8(ascii: "D"): return .key(KeyEvent(key: .left))
        case UInt8(ascii: "H"): return .key(KeyEvent(key: .home))
        case UInt8(ascii: "F"): return .key(KeyEvent(key: .end))
        case UInt8(ascii: "Z"):
            return .key(KeyEvent(key: .tab, modifiers: .shift))
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            return parseExtendedCsi(thirdByte, from: &source)
        default:
            return .key(KeyEvent(key: .unknown([ASCII.escape, UInt8(ascii: "["), thirdByte])))
        }
    }

    /// Accumulate numeric parameters: ESC [ N ; M ~ or ESC [ 1 ; M A/B/C/D or ESC [ N ; M u
    static func parseExtendedCsi(_ thirdByte: UInt8, from source: inout some ByteSource) -> TerminalEvent {
        var params: [UInt8] = [thirdByte]
        // Bounded-retry on nil — same shape as parseSgrMouse and
        // collectBracketedPaste. A CSI sequence is a contract: the
        // ESC[ start has a final byte coming. raw-mode VTIME=1
        // timeouts return nil mid-sequence under tmux/screen
        // multiplexing or when arrow-key bursts straddle a read()
        // boundary. Cap at 30 iterations (~3s at 100ms per timeout);
        // genuinely broken streams fall through to the .unknown
        // fallback rather than hang forever.
        let consecutiveNilLimit = 30
        var consecutiveNils = 0

        while true {
            guard let nextByte = source.readByte() else {
                consecutiveNils += 1
                if consecutiveNils > consecutiveNilLimit {
                    return .key(KeyEvent(key: .unknown([ASCII.escape, UInt8(ascii: "[")] + params)))
                }
                continue
            }
            consecutiveNils = 0
            if nextByte == UInt8(ascii: "~") {
                // Bracketed-paste start: read until the matching end
                // marker and emit one .paste event. Doing this here
                // (not in parseTildeKey) keeps the byte source available
                // — paste-collection needs to keep reading past the
                // tilde, which the regular tilde-key dispatch can't do.
                if isBracketedPasteStart(params) {
                    return collectBracketedPaste(from: &source)
                }
                return parseTildeKey(params)
            }
            // Kitty keyboard protocol: ESC [ keycode ; modifiers u
            if nextByte == UInt8(ascii: "u") {
                return parseKittyKey(params)
            }
            if nextByte >= UInt8(ascii: "A") && nextByte <= UInt8(ascii: "Z") {
                return parseModifiedKey(params, final: nextByte)
            }
            params.append(nextByte)
        }
    }

    /// True iff `params` decode to the bracketed-paste start code (200).
    private static func isBracketedPasteStart(_ params: [UInt8]) -> Bool {
        let text = String(params.map { Character(UnicodeScalar($0)) })
        return Int(text) == TildeCode.bracketedPasteStart
    }

    /// Collect bytes from the source until the matching `ESC [ 2 0 1 ~`
    /// end marker. Bytes inside the wrapper are NOT interpreted — that's
    /// the whole point of bracketed paste, disambiguating typed input
    /// from clipboard content. Returns the payload as a UTF-8 string.
    ///
    /// `readByte()` may return nil mid-payload because raw mode reads
    /// at VTIME=1 (100ms) and the OS can split a large paste across
    /// multiple read() syscalls. Inside this function we KNOW more
    /// bytes are coming — the start marker is a contract that the end
    /// marker will follow — so we treat nil as "wait, retry" rather
    /// than "stream ended." Bounded retry budget guards against a
    /// terminal that opened a paste and disconnected without closing
    /// (mostly a theoretical concern; real terminals do close).
    private static func collectBracketedPaste(from source: inout some ByteSource) -> TerminalEvent {
        var payload: [UInt8] = []
        let endMarker: [UInt8] = [
            ASCII.escape,
            UInt8(ascii: "["),
            UInt8(ascii: "2"),
            UInt8(ascii: "0"),
            UInt8(ascii: "1"),
            UInt8(ascii: "~"),
        ]
        var matched = 0
        // Budget: each VTIME=1 timeout is ~100ms, so this caps total
        // wait at ~3s for the end marker after a transient gap. Real
        // pastes complete in milliseconds; this only fires if the
        // terminal abandoned the paste mid-payload.
        let consecutiveNilLimit = 30
        var consecutiveNils = 0

        while true {
            guard let byte = source.readByte() else {
                consecutiveNils += 1
                if consecutiveNils > consecutiveNilLimit {
                    // Terminal abandoned the paste mid-payload. Return
                    // whatever we collected so the user doesn't lose
                    // typed content; the unread end marker (if it ever
                    // arrives) will fall through to the standard CSI
                    // path and be ignored as an unknown tilde code.
                    break
                }
                continue
            }
            consecutiveNils = 0

            if byte == endMarker[matched] {
                matched += 1
                if matched == endMarker.count {
                    let text = String(decoding: payload, as: Unicode.UTF8.self)
                    return .paste(text)
                }
            } else {
                // Mismatch — flush the partial match into the payload
                // and resume scanning. Bracketed paste payloads can
                // legitimately contain a leading ESC byte that ISN'T
                // the start of the end marker; we must preserve those.
                if matched > 0 {
                    payload.append(contentsOf: endMarker.prefix(matched))
                    matched = 0
                }
                if byte == endMarker[0] {
                    matched = 1
                } else {
                    payload.append(byte)
                }
            }
        }
        // Budget exhausted with no end marker in sight — return the
        // partial payload. Better than dropping all bytes; the
        // collected content is still legitimate paste data.
        let text = String(decoding: payload, as: Unicode.UTF8.self)
        return .paste(text)
    }

    static func parseTildeKey(_ params: [UInt8]) -> TerminalEvent {
        let paramString = String(params.map { Character(UnicodeScalar($0)) })
        let segments = paramString.split(separator: ";").compactMap { Int($0) }
        let code = segments.first ?? 0
        let modifier = segments.count > 1 ? segments[1] : 1

        let mods = decodeModifier(modifier)

        switch code {
        case TildeCode.home:     return .key(KeyEvent(key: .home, modifiers: mods))
        case TildeCode.insert:   return .key(KeyEvent(key: .unknown([2]), modifiers: mods))
        case TildeCode.delete:   return .key(KeyEvent(key: .delete, modifiers: mods))
        case TildeCode.end:      return .key(KeyEvent(key: .end, modifiers: mods))
        case TildeCode.pageUp:   return .key(KeyEvent(key: .pageUp, modifiers: mods))
        case TildeCode.pageDown: return .key(KeyEvent(key: .pageDown, modifiers: mods))
        case TildeCode.f5:       return .key(KeyEvent(key: .f(5), modifiers: mods))
        case TildeCode.f6:       return .key(KeyEvent(key: .f(6), modifiers: mods))
        case TildeCode.f7:       return .key(KeyEvent(key: .f(7), modifiers: mods))
        case TildeCode.f8:       return .key(KeyEvent(key: .f(8), modifiers: mods))
        case TildeCode.f9:       return .key(KeyEvent(key: .f(9), modifiers: mods))
        case TildeCode.f10:      return .key(KeyEvent(key: .f(10), modifiers: mods))
        case TildeCode.f11:      return .key(KeyEvent(key: .f(11), modifiers: mods))
        case TildeCode.f12:      return .key(KeyEvent(key: .f(12), modifiers: mods))
        default: return .key(KeyEvent(key: .unknown(params)))
        }
    }

    static func parseModifiedKey(_ params: [UInt8], final: UInt8) -> TerminalEvent {
        let paramString = String(params.map { Character(UnicodeScalar($0)) })
        let segments = paramString.split(separator: ";").compactMap { Int($0) }
        let modifier = segments.count > 1 ? segments[1] : 1
        let mods = decodeModifier(modifier)

        switch final {
        case UInt8(ascii: "A"): return .key(KeyEvent(key: .up, modifiers: mods))
        case UInt8(ascii: "B"): return .key(KeyEvent(key: .down, modifiers: mods))
        case UInt8(ascii: "C"): return .key(KeyEvent(key: .right, modifiers: mods))
        case UInt8(ascii: "D"): return .key(KeyEvent(key: .left, modifiers: mods))
        case UInt8(ascii: "H"): return .key(KeyEvent(key: .home, modifiers: mods))
        case UInt8(ascii: "F"): return .key(KeyEvent(key: .end, modifiers: mods))
        case UInt8(ascii: "P"): return .key(KeyEvent(key: .f(1), modifiers: mods))
        case UInt8(ascii: "Q"): return .key(KeyEvent(key: .f(2), modifiers: mods))
        case UInt8(ascii: "R"): return .key(KeyEvent(key: .f(3), modifiers: mods))
        case UInt8(ascii: "S"): return .key(KeyEvent(key: .f(4), modifiers: mods))
        default: return .key(KeyEvent(key: .unknown(params + [final])))
        }
    }

    /// Kitty keyboard protocol: ESC [ keycode ; modifiers u
    /// Extended format adds event_type: ESC [ keycode ; modifiers ; event_type u
    /// Event types: 1=press, 2=repeat, 3=release. We only process press/repeat
    /// because key-up events have no meaning in our event model.
    static func parseKittyKey(_ params: [UInt8]) -> TerminalEvent {
        let paramString = String(params.map { Character(UnicodeScalar($0)) })
        let segments = paramString.split(separator: ";").compactMap { Int($0) }
        let keycode = segments.first ?? 0
        let modifier = segments.count > 1 ? segments[1] : 1
        let eventType = segments.count > 2 ? segments[2] : KittyEventType.press

        if eventType == KittyEventType.release { return .key(KeyEvent(key: .unknown([]))) }

        let mods = decodeModifier(modifier)

        switch keycode {
        case Int(ASCII.carriageReturn): return .key(KeyEvent(key: .enter, modifiers: mods))
        case Int(ASCII.tab):            return .key(KeyEvent(key: .tab, modifiers: mods))
        case Int(ASCII.escape):         return .key(KeyEvent(key: .escape, modifiers: mods))
        case Int(ASCII.delete):         return .key(KeyEvent(key: .backspace, modifiers: mods))
        case Int(ASCII.ctrlKeyRange.lowerBound)...Int(ASCII.ctrlKeyRange.upperBound):
            let char = Character(UnicodeScalar(keycode + Int(ASCII.ctrlToLowercaseOffset))!)
            return .key(KeyEvent(key: .character(char), modifiers: mods.union(.ctrl)))
        case ASCII.printableRange:
            let char = Character(UnicodeScalar(keycode)!)
            return .key(KeyEvent(key: .character(char), modifiers: mods))
        default:
            return .key(KeyEvent(key: .unknown(params), modifiers: mods))
        }
    }

    /// xterm modifier parameter: value = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0)
    /// The -1 offset exists because xterm encodes "no modifier" as 1, not 0.
    static func decodeModifier(_ value: Int) -> KeyModifiers {
        let bits = value - 1
        var mods = KeyModifiers()
        if bits & XTermModifier.shiftBit != 0 { mods.insert(.shift) }
        if bits & XTermModifier.altBit != 0 { mods.insert(.alt) }
        if bits & XTermModifier.ctrlBit != 0 { mods.insert(.ctrl) }
        return mods
    }

    // MARK: - SGR 1006 Mouse

    /// Parse SGR 1006 mouse event. Already consumed `ESC [ <`.
    /// Reads semicolon-separated decimal parameters `Cb;Cx;Cy` and final byte
    /// `M` (press/motion) or `m` (release). Cx/Cy are 1-indexed, converted to 0-indexed.
    ///
    /// Bitfield decoding order matters: scroll and motion flags are checked before
    /// press/release because they override button interpretation. A scroll event
    /// with button=0 means scroll-up, not left-click.
    static func parseSgrMouse(from source: inout some ByteSource) -> TerminalEvent {
        var rawBytes: [UInt8] = []
        var finalByte: UInt8 = 0

        // Bounded-retry on nil: raw-mode VTIME=1 timeouts return nil
        // mid-sequence when the OS splits an SGR mouse sequence across
        // read() syscalls. The start marker `ESC[<` is a contract that
        // a final byte (M or m) follows — treat nil as "wait, retry"
        // up to a budget. Budget chosen as 30 (~3s at 100ms per
        // timeout); a real terminal completes a mouse sequence in
        // microseconds, so this only fires if the source genuinely
        // disconnected mid-sequence.
        let consecutiveNilLimit = 30
        var consecutiveNils = 0

        while true {
            guard let byte = source.readByte() else {
                consecutiveNils += 1
                if consecutiveNils > consecutiveNilLimit {
                    return .key(KeyEvent(key: .unknown([ASCII.escape, UInt8(ascii: "["), UInt8(ascii: "<")] + rawBytes)))
                }
                continue
            }
            consecutiveNils = 0
            if byte == UInt8(ascii: "M") || byte == UInt8(ascii: "m") {
                finalByte = byte
                break
            }
            rawBytes.append(byte)
        }

        let paramStr = String(rawBytes.map { Character(UnicodeScalar($0)) })
        let parts = paramStr.split(separator: ";").compactMap { Int($0) }
        guard parts.count == 3 else {
            return .key(KeyEvent(key: .unknown([ASCII.escape, UInt8(ascii: "["), UInt8(ascii: "<")] + rawBytes + [finalByte])))
        }

        let buttonCode = parts[0]
        let column = parts[1] - 1  // SGR coordinates are 1-indexed, we use 0-indexed
        let row = parts[2] - 1

        var mods = KeyModifiers()
        if buttonCode & SGRMouse.shiftBit != 0 { mods.insert(.shift) }
        if buttonCode & SGRMouse.altBit != 0 { mods.insert(.alt) }
        if buttonCode & SGRMouse.ctrlBit != 0 { mods.insert(.ctrl) }

        let isRelease = finalByte == UInt8(ascii: "m")
        let buttonIdentity = buttonCode & SGRMouse.buttonMask

        let kind: MouseEventKind

        if buttonCode & SGRMouse.scrollFlag != 0 {
            let scrollDirection = buttonIdentity & SGRMouse.buttonNumberMask
            kind = scrollDirection == 0 ? .scrollUp : .scrollDown
        } else if buttonCode & SGRMouse.motionFlag != 0 {
            let buttonNumber = buttonIdentity & SGRMouse.buttonNumberMask
            if buttonNumber == 3 {
                kind = .moved
            } else {
                kind = .drag(MouseButton(rawValue: UInt8(buttonNumber)) ?? .left)
            }
        } else if isRelease {
            let buttonNumber = buttonIdentity & SGRMouse.buttonNumberMask
            kind = .release(MouseButton(rawValue: UInt8(buttonNumber)) ?? .left)
        } else {
            let buttonNumber = buttonIdentity & SGRMouse.buttonNumberMask
            if buttonNumber == 3 {
                // X10 legacy: button number 3 in a press context means "button released"
                // because the original X10 protocol had no separate release event.
                // SGR 1006 uses the 'm' final byte for release instead, but some
                // terminals still emit button=3 for compatibility.
                kind = .release(.left)
            } else {
                kind = .press(MouseButton(rawValue: UInt8(buttonNumber)) ?? .left)
            }
        }

        return .mouse(MouseEvent(kind: kind, x: column, y: row, modifiers: mods))
    }

    // MARK: - SS3 (F1-F4)
    //
    // SS3 (Single Shift 3): ESC O followed by P/Q/R/S for F1-F4.
    // Historical VT100 convention. F5+ use CSI tilde sequences instead.
    // Some terminals send CSI P/Q/R/S for F1-F4 — those are handled in parseModifiedKey.

    static func parseSsSequence(from source: inout some ByteSource) -> TerminalEvent {
        guard let thirdByte = source.readByte() else {
            return .key(KeyEvent(key: .escape))
        }

        switch thirdByte {
        case UInt8(ascii: "P"): return .key(KeyEvent(key: .f(1)))
        case UInt8(ascii: "Q"): return .key(KeyEvent(key: .f(2)))
        case UInt8(ascii: "R"): return .key(KeyEvent(key: .f(3)))
        case UInt8(ascii: "S"): return .key(KeyEvent(key: .f(4)))
        default: return .key(KeyEvent(key: .unknown([ASCII.escape, UInt8(ascii: "O"), thirdByte])))
        }
    }

    // MARK: - UTF-8 Decoding
    // Reference: RFC 3629 — lead byte bit pattern determines sequence length.

    static func parseUtf8Character(firstByte: UInt8, from source: inout some ByteSource) -> Character {
        var bytes = [firstByte]
        let expectedLength: Int

        if firstByte & UTF8.singleByteMask == 0 { expectedLength = 1 }
        else if firstByte & UTF8.twoByteMask == UTF8.twoBytePattern { expectedLength = 2 }
        else if firstByte & UTF8.threeByteMask == UTF8.threeBytePattern { expectedLength = 3 }
        else if firstByte & UTF8.fourByteMask == UTF8.fourBytePattern { expectedLength = 4 }
        else { return Character(UnicodeScalar(firstByte)) }

        for _ in 1..<expectedLength {
            guard let nextByte = source.readByte() else { break }
            bytes.append(nextByte)
        }

        let str = String(decoding: bytes, as: Swift.UTF8.self)
        if let char = str.first {
            return char
        }
        return "?"
    }
}
