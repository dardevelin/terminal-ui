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

/// A terminal color, spanning the three ANSI color models: the 16 named
/// palette colors, the 256-color indexed palette, and 24-bit truecolor.
///
/// The named cases emit standard SGR palette codes (30–37 foreground,
/// 90–97 bright foreground, 40–47 / 100–107 background), so the actual
/// hue is whatever the user's terminal theme maps that slot to — a
/// feature, not a bug: apps that stick to named colors automatically
/// respect the user's palette. ``ansi256(_:)`` and ``rgb(_:_:_:)`` pin
/// exact colors at the cost of ignoring the theme. ``default`` is not a
/// color at all but the terminal's own default foreground/background.
///
/// Colors are applied through ``Style`` (in a ``Cell``) or, at the view
/// layer, via modifiers and span helpers:
///
/// ```swift
/// Text("ok").foreground(.green)
/// Text("warn".fg(.yellow).bolded())
/// Text("exact").foreground(.rgb(255, 128, 0))
/// ```
public enum Color: Sendable {
    /// The terminal's own default foreground or background color
    /// (SGR 39 / 49) — whatever the emulator's theme uses when no
    /// color is set. Distinct from any palette entry.
    case `default`
    /// Named ANSI palette black (SGR 30 fg / 40 bg). Rendered hue is
    /// theme-defined.
    case black
    /// Named ANSI palette red (SGR 31 fg / 41 bg). Rendered hue is
    /// theme-defined.
    case red
    /// Named ANSI palette green (SGR 32 fg / 42 bg). Rendered hue is
    /// theme-defined.
    case green
    /// Named ANSI palette yellow (SGR 33 fg / 43 bg). Rendered hue is
    /// theme-defined.
    case yellow
    /// Named ANSI palette blue (SGR 34 fg / 44 bg). Rendered hue is
    /// theme-defined.
    case blue
    /// Named ANSI palette magenta (SGR 35 fg / 45 bg). Rendered hue is
    /// theme-defined.
    case magenta
    /// Named ANSI palette cyan (SGR 36 fg / 46 bg). Rendered hue is
    /// theme-defined.
    case cyan
    /// Named ANSI palette white (SGR 37 fg / 47 bg) — usually light
    /// gray in practice; ``brightWhite`` is the fully bright slot.
    case white
    /// The xterm "bright black" palette slot (SGR 90 fg / 100 bg),
    /// which virtually every theme renders as gray. TerminalUI names
    /// it for what you see, not for the spec's label.
    case gray
    /// Bright ANSI palette red (SGR 91 fg / 101 bg). Rendered hue is
    /// theme-defined.
    case brightRed
    /// Bright ANSI palette green (SGR 92 fg / 102 bg). Rendered hue is
    /// theme-defined.
    case brightGreen
    /// Bright ANSI palette yellow (SGR 93 fg / 103 bg). Rendered hue is
    /// theme-defined.
    case brightYellow
    /// Bright ANSI palette blue (SGR 94 fg / 104 bg). Rendered hue is
    /// theme-defined.
    case brightBlue
    /// Bright ANSI palette magenta (SGR 95 fg / 105 bg). Rendered hue
    /// is theme-defined.
    case brightMagenta
    /// Bright ANSI palette cyan (SGR 96 fg / 106 bg). Rendered hue is
    /// theme-defined.
    case brightCyan
    /// Bright ANSI palette white (SGR 97 fg / 107 bg) — the brightest
    /// palette slot, typically pure white.
    case brightWhite
    /// An index into the xterm 256-color palette (SGR 38;5;N / 48;5;N):
    /// 0–15 mirror the named colors, 16–231 form a 6×6×6 color cube,
    /// 232–255 a 24-step grayscale ramp. Exact — does not follow the
    /// user's 16-color theme.
    case ansi256(UInt8)
    /// 24-bit truecolor (SGR 38;2;R;G;B / 48;2;R;G;B), one 0–255 value
    /// per channel. Exact on truecolor terminals; terminals without
    /// truecolor support approximate or ignore it.
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
