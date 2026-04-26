// HYP-56 — TerminalInk color model.
//
// Three-tier color model mirroring SwiftUI's `Color` and chalk/rich
// conventions:
//
//   - `.named(NamedColor)` — one of the 16 ANSI palette slots
//     (ECMA-48 §8.3.117 SGR 30-37 / 90-97). Every terminal supports
//     these.
//   - `.ansi256(UInt8)` — index into the standard 256-color palette.
//     Most modern terminals support this (xterm-256color and friends).
//   - `.rgb(r, g, b)` — full 24-bit truecolor. Modern emulators
//     (iTerm2, kitty, alacritty, GNOME Terminal) support this; older
//     ones don't. `ColorCapability.downgrade(_:)` collapses RGB to the
//     supported tier at write time.
//   - `.default` — the terminal's user-configured default color
//     (CSI 39 m / CSI 49 m). Useful for "stop overriding" without
//     resetting other SGR attributes.
//
// Semantic shorthand (`.success`, `.warning`, etc.) is a thin layer
// on top — apps should reach for these instead of hardcoded named
// colors so a future theme system can re-skin them.

/// One of the 16 ANSI standard color slots. Order matches the SGR
/// 30-37 (foreground) / 90-97 (bright foreground) sequence — ECMA-48
/// §8.3.117. All terminals, including dumb ones, support this palette.
public enum NamedColor: Sendable, Hashable, CaseIterable {
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case brightBlack    // a.k.a. "gray" / "dark gray"
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightMagenta
    case brightCyan
    case brightWhite

    /// Foreground SGR offset — `30 + offset` for non-bright,
    /// `90 + offset - 8` for bright variants. The `ANSICode` builder
    /// uses this to compose the final escape sequence.
    var sgrOffset: Int {
        switch self {
        case .black:         return 0
        case .red:           return 1
        case .green:         return 2
        case .yellow:        return 3
        case .blue:          return 4
        case .magenta:       return 5
        case .cyan:          return 6
        case .white:         return 7
        case .brightBlack:   return 8
        case .brightRed:     return 9
        case .brightGreen:   return 10
        case .brightYellow:  return 11
        case .brightBlue:    return 12
        case .brightMagenta: return 13
        case .brightCyan:    return 14
        case .brightWhite:   return 15
        }
    }
}

/// A color in TerminalInk's color model. Use `.named(...)` for
/// guaranteed-supported palette slots, `.ansi256(...)` for the
/// 256-color palette, `.rgb(...)` for truecolor.
///
/// ## Downgrade
///
/// At write time, `ColorCapability.downgrade(_:)` collapses higher-
/// tier colors to whatever the terminal supports. Construct colors
/// freely with the highest fidelity you have; the runtime handles
/// degradation. See `ColorCapability` for detection rules.
public enum InkColor: Sendable, Hashable {
    case `default`
    case named(NamedColor)
    case ansi256(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    // MARK: - Semantic shorthand
    //
    // These map onto the 16-color palette so they render correctly
    // even on the most-restricted terminals. Apps wanting richer
    // colors should override via a theme layer (filed separately).

    /// Default emphasis color — `.brightWhite` on dark terminals.
    public static let primary: InkColor = .named(.brightWhite)
    /// Secondary / less-prominent text — `.white`.
    public static let secondary: InkColor = .named(.white)
    /// Success / positive — `.brightGreen`.
    public static let success: InkColor = .named(.brightGreen)
    /// Warning / caution — `.brightYellow`.
    public static let warning: InkColor = .named(.brightYellow)
    /// Error / failure — `.brightRed`.
    public static let error: InkColor = .named(.brightRed)
    /// Muted / de-emphasized — `.brightBlack` (a.k.a. dark gray).
    public static let muted: InkColor = .named(.brightBlack)
}
