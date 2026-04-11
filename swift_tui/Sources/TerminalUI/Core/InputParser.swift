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
// Reference: xterm ctlseqs — CSI < Cb ; Cx ; Cy M/m
// Cb encodes button identity + modifiers in a single integer via bitfields.

private enum SGRMouse {
    static let shiftBit = 4
    static let altBit = 8
    static let ctrlBit = 16
    static let motionFlag = 32
    static let scrollFlag = 64
    /// Extracts button identity: bits 0-1 (button number) and bit 6 (scroll indicator)
    static let buttonMask = 0x43
    static let buttonNumberMask = 3
}

// MARK: - xterm Modifier Encoding
// Reference: xterm — modifier parameter = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0)
// The -1 offset exists because xterm encodes "no modifier" as 1, not 0.

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
}

// MARK: - Kitty Keyboard Protocol
// Reference: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
// Event types in extended format: ESC [ keycode ; modifiers ; event_type u

private enum KittyEventType {
    static let press = 1
    static let `repeat` = 2
    static let release = 3
}

// MARK: - UTF-8 Lead Byte Masks
// Reference: RFC 3629 — each lead byte pattern determines the sequence length.

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
public enum InputParser {

    public static func readEvent() -> TerminalEvent? {
        var buf = [UInt8](repeating: 0, count: 6)
        let bytesRead = read(STDIN_FILENO, &buf, 1)
        guard bytesRead == 1 else { return nil }

        let byte = buf[0]

        if ASCII.ctrlKeyRange.contains(byte) {
            if byte == ASCII.carriageReturn { return .key(KeyEvent(key: .enter)) }
            if byte == ASCII.tab { return .key(KeyEvent(key: .tab)) }
            if byte == ASCII.backspace { return .key(KeyEvent(key: .backspace)) }
            let char = Character(UnicodeScalar(byte + ASCII.ctrlToLowercaseOffset))
            return .key(KeyEvent(key: .character(char), modifiers: .ctrl))
        }

        if byte == ASCII.escape {
            return parseEscapeSequence(&buf)
        }

        if byte == ASCII.delete {
            return .key(KeyEvent(key: .backspace))
        }

        let char = parseUtf8Character(firstByte: byte, buf: &buf)
        return .key(KeyEvent(key: .character(char)))
    }

    public static func readKey() -> KeyEvent? {
        guard let event = readEvent() else { return nil }
        if case .key(let keyEvent) = event { return keyEvent }
        return nil
    }

    // MARK: - Escape Sequences

    static func parseEscapeSequence(_ buf: inout [UInt8]) -> TerminalEvent {
        var secondByte: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &secondByte, 1)
        if bytesRead == 0 {
            return .key(KeyEvent(key: .escape))
        }

        if secondByte == UInt8(ascii: "[") {
            return parseCsiSequence(&buf)
        }

        if secondByte == UInt8(ascii: "O") {
            return parseSsSequence(&buf)
        }

        if secondByte == ASCII.carriageReturn {
            return .key(KeyEvent(key: .enter, modifiers: .alt))
        }

        let char = Character(UnicodeScalar(secondByte))
        return .key(KeyEvent(key: .character(char), modifiers: .alt))
    }

    static func parseCsiSequence(_ buf: inout [UInt8]) -> TerminalEvent {
        var thirdByte: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &thirdByte, 1)
        guard bytesRead == 1 else { return .key(KeyEvent(key: .escape)) }

        // SGR 1006 mouse: ESC [ < Cb ; Cx ; Cy M/m
        if thirdByte == UInt8(ascii: "<") {
            return parseSgrMouse()
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
            return parseExtendedCsi(thirdByte)
        default:
            return .key(KeyEvent(key: .unknown([ASCII.escape, UInt8(ascii: "["), thirdByte])))
        }
    }

    /// Accumulate numeric parameters: ESC [ N ; M ~ or ESC [ 1 ; M A/B/C/D or ESC [ N ; M u
    static func parseExtendedCsi(_ thirdByte: UInt8) -> TerminalEvent {
        var params: [UInt8] = [thirdByte]
        while true {
            var nextByte: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &nextByte, 1)
            guard bytesRead == 1 else { break }

            if nextByte == UInt8(ascii: "~") {
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
        return .key(KeyEvent(key: .unknown([ASCII.escape, UInt8(ascii: "[")] + params)))
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

    /// Parse SGR mouse event: ESC [ < Cb ; Cx ; Cy M/m
    /// Already consumed `ESC [ <`, now read `Cb;Cx;Cy` and final `M` (press) or `m` (release).
    static func parseSgrMouse() -> TerminalEvent {
        var rawBytes: [UInt8] = []
        var finalByte: UInt8 = 0

        while true {
            var byte: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &byte, 1)
            guard bytesRead == 1 else {
                return .key(KeyEvent(key: .unknown([ASCII.escape, UInt8(ascii: "["), UInt8(ascii: "<")] + rawBytes)))
            }
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
                // X10 compatibility: button 3 in press context means release
                kind = .release(.left)
            } else {
                kind = .press(MouseButton(rawValue: UInt8(buttonNumber)) ?? .left)
            }
        }

        return .mouse(MouseEvent(kind: kind, x: column, y: row, modifiers: mods))
    }

    // MARK: - SS3 (F1-F4)

    static func parseSsSequence(_ buf: inout [UInt8]) -> TerminalEvent {
        var thirdByte: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &thirdByte, 1)
        guard bytesRead == 1 else { return .key(KeyEvent(key: .escape)) }

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

    static func parseUtf8Character(firstByte: UInt8, buf: inout [UInt8]) -> Character {
        var bytes = [firstByte]
        let expectedLength: Int

        if firstByte & UTF8.singleByteMask == 0 { expectedLength = 1 }
        else if firstByte & UTF8.twoByteMask == UTF8.twoBytePattern { expectedLength = 2 }
        else if firstByte & UTF8.threeByteMask == UTF8.threeBytePattern { expectedLength = 3 }
        else if firstByte & UTF8.fourByteMask == UTF8.fourBytePattern { expectedLength = 4 }
        else { return Character(UnicodeScalar(firstByte)) }

        for _ in 1..<expectedLength {
            var nextByte: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &nextByte, 1)
            guard bytesRead == 1 else { break }
            bytes.append(nextByte)
        }

        let str = String(decoding: bytes, as: Swift.UTF8.self)
        if let char = str.first {
            return char
        }
        return "?"
    }
}
