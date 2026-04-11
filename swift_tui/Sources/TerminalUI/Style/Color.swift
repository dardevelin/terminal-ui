public enum Color: Sendable {
    case `default`
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case gray
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightMagenta
    case brightCyan
    case brightWhite
    case ansi256(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    var foregroundCode: String {
        switch self {
        case .default: "\u{1B}[39m"
        case .black: "\u{1B}[30m"
        case .red: "\u{1B}[31m"
        case .green: "\u{1B}[32m"
        case .yellow: "\u{1B}[33m"
        case .blue: "\u{1B}[34m"
        case .magenta: "\u{1B}[35m"
        case .cyan: "\u{1B}[36m"
        case .white: "\u{1B}[37m"
        case .gray: "\u{1B}[90m"
        case .brightRed: "\u{1B}[91m"
        case .brightGreen: "\u{1B}[92m"
        case .brightYellow: "\u{1B}[93m"
        case .brightBlue: "\u{1B}[94m"
        case .brightMagenta: "\u{1B}[95m"
        case .brightCyan: "\u{1B}[96m"
        case .brightWhite: "\u{1B}[97m"
        case .ansi256(let n): "\u{1B}[38;5;\(n)m"
        case .rgb(let r, let g, let b): "\u{1B}[38;2;\(r);\(g);\(b)m"
        }
    }

    /// Return a dimmed version of this color — shifts bright variants to their
    /// dark counterparts, reduces RGB intensity by ~50%, and falls back to
    /// the provided tint for colors that can't be dimmed meaningfully.
    func dimmed(fallback: Color) -> Color {
        switch self {
        // Bright → dark counterpart
        case .brightRed:     return .red
        case .brightGreen:   return .green
        case .brightYellow:  return .yellow
        case .brightBlue:    return .blue
        case .brightMagenta: return .magenta
        case .brightCyan:    return .cyan
        case .brightWhite:   return .white
        case .white:         return .gray
        // Already dark — shift to gray
        case .red:           return .ansi256(88)   // dark red
        case .green:         return .ansi256(22)   // dark green
        case .yellow:        return .ansi256(136)  // dark yellow
        case .blue:          return .ansi256(18)   // dark blue
        case .magenta:       return .ansi256(90)   // dark magenta
        case .cyan:          return .ansi256(30)   // dark cyan
        case .gray:          return .ansi256(240)  // darker gray
        case .black:         return .black
        case .default:       return fallback
        // RGB — reduce each channel by ~50%
        case .rgb(let r, let g, let b):
            return .rgb(r / 2, g / 2, b / 2)
        // ANSI 256 — approximate dimming via grayscale ramp or halving
        case .ansi256(let n):
            if n >= 232 && n <= 255 {
                // Grayscale ramp (232=black..255=white) — shift down
                let dimmed = max(232, Int(n) - 6)
                return .ansi256(UInt8(dimmed))
            }
            // For the 6x6x6 color cube (16-231), reduce each component
            if n >= 16 && n <= 231 {
                let idx = Int(n) - 16
                let b = idx % 6
                let g = (idx / 6) % 6
                let r = idx / 36
                let dr = max(0, r / 2)
                let dg = max(0, g / 2)
                let db = max(0, b / 2)
                return .ansi256(UInt8(16 + dr * 36 + dg * 6 + db))
            }
            return fallback
        }
    }

    var backgroundCode: String {
        switch self {
        case .default: "\u{1B}[49m"
        case .black: "\u{1B}[40m"
        case .red: "\u{1B}[41m"
        case .green: "\u{1B}[42m"
        case .yellow: "\u{1B}[43m"
        case .blue: "\u{1B}[44m"
        case .magenta: "\u{1B}[45m"
        case .cyan: "\u{1B}[46m"
        case .white: "\u{1B}[47m"
        case .gray: "\u{1B}[100m"
        case .brightRed: "\u{1B}[101m"
        case .brightGreen: "\u{1B}[102m"
        case .brightYellow: "\u{1B}[103m"
        case .brightBlue: "\u{1B}[104m"
        case .brightMagenta: "\u{1B}[105m"
        case .brightCyan: "\u{1B}[106m"
        case .brightWhite: "\u{1B}[107m"
        case .ansi256(let n): "\u{1B}[48;5;\(n)m"
        case .rgb(let r, let g, let b): "\u{1B}[48;2;\(r);\(g);\(b)m"
        }
    }
}
