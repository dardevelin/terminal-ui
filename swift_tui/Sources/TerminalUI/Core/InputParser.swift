#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Parses raw terminal bytes into KeyEvents.
// Handles ANSI escape sequences for special keys.

public enum InputParser {

    public static func readKey() -> KeyEvent? {
        var buf = [UInt8](repeating: 0, count: 6)
        let n = read(STDIN_FILENO, &buf, 1)
        guard n == 1 else { return nil }

        let byte = buf[0]

        // Ctrl+key combinations (0x01 - 0x1a)
        if byte >= 1 && byte <= 26 {
            let char = Character(UnicodeScalar(byte + 96))
            if byte == 13 { return KeyEvent(key: .enter) }
            if byte == 9 { return KeyEvent(key: .tab) }
            if byte == 8 { return KeyEvent(key: .backspace) }
            return KeyEvent(key: .character(char), modifiers: .ctrl)
        }

        // Escape or escape sequence
        if byte == 27 {
            return parseEscapeSequence(&buf)
        }

        // Backspace (127)
        if byte == 127 {
            return KeyEvent(key: .backspace)
        }

        // Regular character — may be multi-byte UTF-8
        let char = parseUtf8Character(firstByte: byte, buf: &buf)
        return KeyEvent(key: .character(char))
    }

    static func parseEscapeSequence(_ buf: inout [UInt8]) -> KeyEvent {
        // Try to read the next byte with a short timeout
        var second: UInt8 = 0
        let n = read(STDIN_FILENO, &second, 1)
        if n == 0 {
            return KeyEvent(key: .escape)
        }

        if second == UInt8(ascii: "[") {
            return parseCsiSequence(&buf)
        }

        if second == UInt8(ascii: "O") {
            return parseSsSequence(&buf)
        }

        // Alt+key
        let char = Character(UnicodeScalar(second))
        return KeyEvent(key: .character(char), modifiers: .alt)
    }

    static func parseCsiSequence(_ buf: inout [UInt8]) -> KeyEvent {
        var third: UInt8 = 0
        let n = read(STDIN_FILENO, &third, 1)
        guard n == 1 else { return KeyEvent(key: .escape) }

        switch third {
        case UInt8(ascii: "A"): return KeyEvent(key: .up)
        case UInt8(ascii: "B"): return KeyEvent(key: .down)
        case UInt8(ascii: "C"): return KeyEvent(key: .right)
        case UInt8(ascii: "D"): return KeyEvent(key: .left)
        case UInt8(ascii: "H"): return KeyEvent(key: .home)
        case UInt8(ascii: "F"): return KeyEvent(key: .end)
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            // Extended sequence like ESC[1~ (Home), ESC[3~ (Delete), etc.
            var fourth: UInt8 = 0
            let n2 = read(STDIN_FILENO, &fourth, 1)
            guard n2 == 1 else { return KeyEvent(key: .unknown([27, 91, third])) }

            if fourth == UInt8(ascii: "~") {
                switch third {
                case UInt8(ascii: "1"): return KeyEvent(key: .home)
                case UInt8(ascii: "2"): return KeyEvent(key: .unknown([27, 91, third, fourth])) // Insert
                case UInt8(ascii: "3"): return KeyEvent(key: .delete)
                case UInt8(ascii: "4"): return KeyEvent(key: .end)
                case UInt8(ascii: "5"): return KeyEvent(key: .pageUp)
                case UInt8(ascii: "6"): return KeyEvent(key: .pageDown)
                default: return KeyEvent(key: .unknown([27, 91, third, fourth]))
                }
            }

            // Could be ESC[15~ (F5) etc. — drain remaining bytes
            return KeyEvent(key: .unknown([27, 91, third, fourth]))

        default:
            return KeyEvent(key: .unknown([27, 91, third]))
        }
    }

    static func parseSsSequence(_ buf: inout [UInt8]) -> KeyEvent {
        var third: UInt8 = 0
        let n = read(STDIN_FILENO, &third, 1)
        guard n == 1 else { return KeyEvent(key: .escape) }

        switch third {
        case UInt8(ascii: "P"): return KeyEvent(key: .f(1))
        case UInt8(ascii: "Q"): return KeyEvent(key: .f(2))
        case UInt8(ascii: "R"): return KeyEvent(key: .f(3))
        case UInt8(ascii: "S"): return KeyEvent(key: .f(4))
        default: return KeyEvent(key: .unknown([27, 79, third]))
        }
    }

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
