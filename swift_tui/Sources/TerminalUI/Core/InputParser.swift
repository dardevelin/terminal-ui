#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Parses raw terminal bytes into KeyEvents or MouseEvents.
/// Handles ANSI escape sequences, SGR 1006 mouse protocol, and UTF-8.
public enum InputParser {

    /// Read one input event from stdin. Blocks until input is available.
    public static func readEvent() -> TerminalEvent? {
        var buf = [UInt8](repeating: 0, count: 6)
        let n = read(STDIN_FILENO, &buf, 1)
        guard n == 1 else { return nil }

        let byte = buf[0]

        // Ctrl+key combinations (0x01 - 0x1a)
        if byte >= 1 && byte <= 26 {
            if byte == 13 { return .key(KeyEvent(key: .enter)) }
            if byte == 9 { return .key(KeyEvent(key: .tab)) }
            if byte == 8 { return .key(KeyEvent(key: .backspace)) }
            let char = Character(UnicodeScalar(byte + 96))
            return .key(KeyEvent(key: .character(char), modifiers: .ctrl))
        }

        // Escape or escape sequence
        if byte == 27 {
            return parseEscapeSequence(&buf)
        }

        // Backspace (127)
        if byte == 127 {
            return .key(KeyEvent(key: .backspace))
        }

        // Regular character — may be multi-byte UTF-8
        let char = parseUtf8Character(firstByte: byte, buf: &buf)
        return .key(KeyEvent(key: .character(char)))
    }

    /// Legacy convenience — returns only key events.
    public static func readKey() -> KeyEvent? {
        guard let event = readEvent() else { return nil }
        if case .key(let k) = event { return k }
        return nil
    }

    // MARK: - Escape Sequences

    static func parseEscapeSequence(_ buf: inout [UInt8]) -> TerminalEvent {
        var second: UInt8 = 0
        let n = read(STDIN_FILENO, &second, 1)
        if n == 0 {
            return .key(KeyEvent(key: .escape))
        }

        if second == UInt8(ascii: "[") {
            return parseCsiSequence(&buf)
        }

        if second == UInt8(ascii: "O") {
            return parseSsSequence(&buf)
        }

        // Alt+Enter (ESC + CR)
        if second == 13 {
            return .key(KeyEvent(key: .enter, modifiers: .alt))
        }

        // Alt+key
        let char = Character(UnicodeScalar(second))
        return .key(KeyEvent(key: .character(char), modifiers: .alt))
    }

    static func parseCsiSequence(_ buf: inout [UInt8]) -> TerminalEvent {
        var third: UInt8 = 0
        let n = read(STDIN_FILENO, &third, 1)
        guard n == 1 else { return .key(KeyEvent(key: .escape)) }

        // SGR 1006 mouse: ESC [ < ...
        if third == UInt8(ascii: "<") {
            return parseSgrMouse()
        }

        switch third {
        case UInt8(ascii: "A"): return .key(KeyEvent(key: .up))
        case UInt8(ascii: "B"): return .key(KeyEvent(key: .down))
        case UInt8(ascii: "C"): return .key(KeyEvent(key: .right))
        case UInt8(ascii: "D"): return .key(KeyEvent(key: .left))
        case UInt8(ascii: "H"): return .key(KeyEvent(key: .home))
        case UInt8(ascii: "F"): return .key(KeyEvent(key: .end))
        case UInt8(ascii: "Z"):
            // Shift+Tab (reverse tab / backtab)
            return .key(KeyEvent(key: .tab, modifiers: .shift))
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            return parseExtendedCsi(third)
        default:
            return .key(KeyEvent(key: .unknown([27, 91, third])))
        }
    }

    static func parseExtendedCsi(_ third: UInt8) -> TerminalEvent {
        // Accumulate numeric parameters: ESC [ N ; M ~ or ESC [ 1 ; M A/B/C/D or ESC [ N ; M u
        var params: [UInt8] = [third]
        while true {
            var next: UInt8 = 0
            let n = read(STDIN_FILENO, &next, 1)
            guard n == 1 else { break }

            if next == UInt8(ascii: "~") {
                return parseTildeKey(params)
            }
            if next == UInt8(ascii: "u") {
                // Kitty keyboard protocol: ESC [ keycode ; modifiers u
                return parseKittyKey(params)
            }
            if next >= UInt8(ascii: "A") && next <= UInt8(ascii: "Z") {
                return parseModifiedKey(params, final: next)
            }
            params.append(next)
        }
        return .key(KeyEvent(key: .unknown([27, 91] + params)))
    }

    static func parseTildeKey(_ params: [UInt8]) -> TerminalEvent {
        // Parse the number before ~
        let numStr = String(params.map { Character(UnicodeScalar($0)) })
        let segments = numStr.split(separator: ";").compactMap { Int($0) }
        let code = segments.first ?? 0
        let modifier = segments.count > 1 ? segments[1] : 1

        let mods = decodeModifier(modifier)

        switch code {
        case 1: return .key(KeyEvent(key: .home, modifiers: mods))
        case 2: return .key(KeyEvent(key: .unknown([2]), modifiers: mods)) // Insert
        case 3: return .key(KeyEvent(key: .delete, modifiers: mods))
        case 4: return .key(KeyEvent(key: .end, modifiers: mods))
        case 5: return .key(KeyEvent(key: .pageUp, modifiers: mods))
        case 6: return .key(KeyEvent(key: .pageDown, modifiers: mods))
        case 15: return .key(KeyEvent(key: .f(5), modifiers: mods))
        case 17: return .key(KeyEvent(key: .f(6), modifiers: mods))
        case 18: return .key(KeyEvent(key: .f(7), modifiers: mods))
        case 19: return .key(KeyEvent(key: .f(8), modifiers: mods))
        case 20: return .key(KeyEvent(key: .f(9), modifiers: mods))
        case 21: return .key(KeyEvent(key: .f(10), modifiers: mods))
        case 23: return .key(KeyEvent(key: .f(11), modifiers: mods))
        case 24: return .key(KeyEvent(key: .f(12), modifiers: mods))
        default: return .key(KeyEvent(key: .unknown(params)))
        }
    }

    static func parseModifiedKey(_ params: [UInt8], final: UInt8) -> TerminalEvent {
        let numStr = String(params.map { Character(UnicodeScalar($0)) })
        let segments = numStr.split(separator: ";").compactMap { Int($0) }
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

    /// Parse kitty keyboard protocol: ESC [ keycode ; modifiers u
    /// Also handles extended format: ESC [ keycode ; modifiers ; event_type u
    /// Event types: 1=press, 2=repeat, 3=release. We only act on press/repeat.
    static func parseKittyKey(_ params: [UInt8]) -> TerminalEvent {
        let numStr = String(params.map { Character(UnicodeScalar($0)) })
        let segments = numStr.split(separator: ";").compactMap { Int($0) }
        let keycode = segments.first ?? 0
        let modifier = segments.count > 1 ? segments[1] : 1
        let eventType = segments.count > 2 ? segments[2] : 1  // 1=press, 2=repeat, 3=release

        // Ignore key release events
        if eventType == 3 { return .key(KeyEvent(key: .unknown([]))) }

        let mods = decodeModifier(modifier)

        switch keycode {
        case 13: return .key(KeyEvent(key: .enter, modifiers: mods))
        case 9:  return .key(KeyEvent(key: .tab, modifiers: mods))
        case 27: return .key(KeyEvent(key: .escape, modifiers: mods))
        case 127: return .key(KeyEvent(key: .backspace, modifiers: mods))
        case 1...26:
            let char = Character(UnicodeScalar(keycode + 96)!)
            return .key(KeyEvent(key: .character(char), modifiers: mods.union(.ctrl)))
        case 32...126:
            let char = Character(UnicodeScalar(keycode)!)
            return .key(KeyEvent(key: .character(char), modifiers: mods))
        default:
            return .key(KeyEvent(key: .unknown(params), modifiers: mods))
        }
    }

    /// Decode xterm modifier parameter: value = 1 + (shift? 1:0) + (alt? 2:0) + (ctrl? 4:0)
    static func decodeModifier(_ value: Int) -> KeyModifiers {
        let bits = value - 1
        var mods = KeyModifiers()
        if bits & 1 != 0 { mods.insert(.shift) }
        if bits & 2 != 0 { mods.insert(.alt) }
        if bits & 4 != 0 { mods.insert(.ctrl) }
        return mods
    }

    // MARK: - SGR 1006 Mouse

    /// Parse SGR mouse event: ESC [ < Cb ; Cx ; Cy M/m
    /// Already consumed `ESC [ <`, now read `Cb;Cx;Cy` and final `M` or `m`.
    static func parseSgrMouse() -> TerminalEvent {
        var bytes: [UInt8] = []
        var final: UInt8 = 0

        // Read until we hit M (press) or m (release)
        while true {
            var b: UInt8 = 0
            let n = read(STDIN_FILENO, &b, 1)
            guard n == 1 else {
                return .key(KeyEvent(key: .unknown([27, 91, 60] + bytes)))
            }
            if b == UInt8(ascii: "M") || b == UInt8(ascii: "m") {
                final = b
                break
            }
            bytes.append(b)
        }

        // Parse "Cb;Cx;Cy"
        let paramStr = String(bytes.map { Character(UnicodeScalar($0)) })
        let parts = paramStr.split(separator: ";").compactMap { Int($0) }
        guard parts.count == 3 else {
            return .key(KeyEvent(key: .unknown([27, 91, 60] + bytes + [final])))
        }

        let cb = parts[0]
        let cx = parts[1] - 1  // Convert 1-indexed to 0-indexed
        let cy = parts[2] - 1

        // Decode modifiers from button code
        var mods = KeyModifiers()
        if cb & 4 != 0 { mods.insert(.shift) }
        if cb & 8 != 0 { mods.insert(.alt) }
        if cb & 16 != 0 { mods.insert(.ctrl) }

        let isRelease = final == UInt8(ascii: "m")
        let buttonBits = cb & 0x43  // bits 0-1 and bit 6

        let kind: MouseEventKind

        if cb & 64 != 0 {
            // Scroll events
            let scrollButton = buttonBits & 3
            kind = scrollButton == 0 ? .scrollUp : .scrollDown
        } else if cb & 32 != 0 {
            // Drag / motion
            let btn = buttonBits & 3
            if btn == 3 {
                kind = .moved
            } else {
                kind = .drag(MouseButton(rawValue: UInt8(btn)) ?? .left)
            }
        } else if isRelease {
            let btn = buttonBits & 3
            kind = .release(MouseButton(rawValue: UInt8(btn)) ?? .left)
        } else {
            let btn = buttonBits & 3
            if btn == 3 {
                kind = .release(.left) // X10 compat release
            } else {
                kind = .press(MouseButton(rawValue: UInt8(btn)) ?? .left)
            }
        }

        return .mouse(MouseEvent(kind: kind, x: cx, y: cy, modifiers: mods))
    }

    // MARK: - SS3 (F1-F4)

    static func parseSsSequence(_ buf: inout [UInt8]) -> TerminalEvent {
        var third: UInt8 = 0
        let n = read(STDIN_FILENO, &third, 1)
        guard n == 1 else { return .key(KeyEvent(key: .escape)) }

        switch third {
        case UInt8(ascii: "P"): return .key(KeyEvent(key: .f(1)))
        case UInt8(ascii: "Q"): return .key(KeyEvent(key: .f(2)))
        case UInt8(ascii: "R"): return .key(KeyEvent(key: .f(3)))
        case UInt8(ascii: "S"): return .key(KeyEvent(key: .f(4)))
        default: return .key(KeyEvent(key: .unknown([27, 79, third])))
        }
    }

    // MARK: - UTF-8

    static func parseUtf8Character(firstByte: UInt8, buf: inout [UInt8]) -> Character {
        var bytes = [firstByte]
        let expectedLength: Int

        if firstByte & 0x80 == 0 { expectedLength = 1 }
        else if firstByte & 0xE0 == 0xC0 { expectedLength = 2 }
        else if firstByte & 0xF0 == 0xE0 { expectedLength = 3 }
        else if firstByte & 0xF8 == 0xF0 { expectedLength = 4 }
        else { return Character(UnicodeScalar(firstByte)) }

        for _ in 1..<expectedLength {
            var next: UInt8 = 0
            let n = read(STDIN_FILENO, &next, 1)
            guard n == 1 else { break }
            bytes.append(next)
        }

        let str = String(decoding: bytes, as: UTF8.self)
        if let char = str.first {
            return char
        }
        return "?"
    }
}
