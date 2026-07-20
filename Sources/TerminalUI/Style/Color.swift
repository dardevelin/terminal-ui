import TerminalInk

// `Color` is now a thin SGR-emitting facade over
// `TerminalInk.InkColor`. The public case shape stays
// source-compatible (every existing `Color.red`, `.brightRed`,
// `.ansi256(...)`, `.rgb(...)` call still compiles); the SGR
// generation routes through `ANSICode.foreground / .background` so
// the codes match the rest of the framework byte-for-byte.
//
// `.dimmed(fallback:)` stays here — it's a TUI-specific concern
// (focus dimming, theme tinting) that has no place in the standalone
// `TerminalInk` library. It still operates entirely on the local
// `Color` cases without round-tripping through `InkColor`.
//
// `.gray` is the one TerminalUI-specific name; it maps to
// `NamedColor.brightBlack` (the xterm convention "gray = SGR 90").

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

    /// Lower this `Color` to the equivalent `InkColor` for SGR
    /// generation. Pure mapping — no behavioural shift, just an
    /// adapter to the shared ECMA-48 builder in `TerminalInk`.
    var asInkColor: InkColor {
        switch self {
        case .default: return .default
        case .black:         return .named(.black)
        case .red:           return .named(.red)
        case .green:         return .named(.green)
        case .yellow:        return .named(.yellow)
        case .blue:          return .named(.blue)
        case .magenta:       return .named(.magenta)
        case .cyan:          return .named(.cyan)
        case .white:         return .named(.white)
        // TerminalUI's `.gray` is xterm's "bright black" (SGR 90) —
        // the TerminalInk name comes from ECMA-48's terminology
        // ("brightBlack"), but the rendered color is identical.
        case .gray:          return .named(.brightBlack)
        case .brightRed:     return .named(.brightRed)
        case .brightGreen:   return .named(.brightGreen)
        case .brightYellow:  return .named(.brightYellow)
        case .brightBlue:    return .named(.brightBlue)
        case .brightMagenta: return .named(.brightMagenta)
        case .brightCyan:    return .named(.brightCyan)
        case .brightWhite:   return .named(.brightWhite)
        case .ansi256(let n): return .ansi256(n)
        case .rgb(let r, let g, let b): return .rgb(r, g, b)
        }
    }

    /// SGR foreground sequence. Routed through
    /// `TerminalInk.ANSICode.foreground` so the byte output matches
    /// the rest of the framework's styled-output stack (swtui, Log,
    /// `ink()`).
    var foregroundCode: String { ANSICode.foreground(asInkColor) }

    /// SGR background sequence — counterpart to `foregroundCode`.
    var backgroundCode: String { ANSICode.background(asInkColor) }

    /// Return a dimmed version of this color — shifts bright variants to their
    /// dark counterparts, reduces RGB intensity by ~50%, and falls back to
    /// the provided tint for colors that can't be dimmed meaningfully.
    ///
    /// TerminalUI-specific (focus / theme dimming). Stays on `Color`
    /// rather than moving to `InkColor` because dimming is a UI
    /// concern, not a primitive color-model concern.
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
}
