// SGR escape sequence generation.
//
// Per ECMA-48 §8.3.117 (SGR — Select Graphic Rendition):
//
//   CSI Pn ; ... ; Pn m
//
// where each `Pn` is a parameter selecting an attribute. The relevant
// codes for color:
//
//   30-37  set foreground to the named color (offset from black)
//   38;5;n set foreground to ansi256 palette slot n
//   38;2;r;g;b set foreground to 24-bit RGB
//   39     reset foreground to terminal default
//   40-47  set background to the named color
//   48;5;n set background to ansi256
//   48;2;r;g;b set background to 24-bit RGB
//   49     reset background to terminal default
//   90-97  set foreground to the bright variant (xterm extension,
//          codified as ISO-8613-3)
//   100-107 set background to the bright variant
//   0      reset all attributes
//
// `ANSICode` is a static-only helper — no instances. Callers build
// sequences directly via `ANSICode.foreground(c)`, etc., and append
// them to whatever stream they're writing to.

/// Builder for SGR (Select Graphic Rendition) escape sequences.
public enum ANSICode {
    /// CSI prefix — escape character + `[`. ECMA-48 §5.4.
    public static let csi = "\u{1B}["

    /// SGR-0: reset all attributes (color, bold, italic, underline,
    /// etc.) to the terminal default.
    public static let reset: String = "\(csi)0m"

    /// Build the foreground SGR sequence for `color`. Caller is
    /// responsible for closing with `reset` (or another color) once
    /// styled output ends — this only sets, never restores.
    public static func foreground(_ color: InkColor) -> String {
        switch color {
        case .default:
            // CSI 39 m — reset foreground to terminal default WITHOUT
            // touching background or other attributes.
            return "\(csi)39m"
        case .named(let n):
            // SGR 30-37 for the standard palette, 90-97 for bright.
            // The bright SGR codes are 90 + (offset - 8) per xterm /
            // ISO-8613-3.
            let offset = n.sgrOffset
            let code = offset < 8 ? 30 + offset : 90 + (offset - 8)
            return "\(csi)\(code)m"
        case .ansi256(let n):
            return "\(csi)38;5;\(n)m"
        case .rgb(let r, let g, let b):
            return "\(csi)38;2;\(r);\(g);\(b)m"
        }
    }

    /// Build the background SGR sequence for `color`. Mirrors
    /// `foreground(_:)` with the 40 / 100 / 49 / 48;5;n / 48;2;r;g;b
    /// codes per ECMA-48.
    public static func background(_ color: InkColor) -> String {
        switch color {
        case .default:
            return "\(csi)49m"
        case .named(let n):
            let offset = n.sgrOffset
            let code = offset < 8 ? 40 + offset : 100 + (offset - 8)
            return "\(csi)\(code)m"
        case .ansi256(let n):
            return "\(csi)48;5;\(n)m"
        case .rgb(let r, let g, let b):
            return "\(csi)48;2;\(r);\(g);\(b)m"
        }
    }

    /// Build the SGR sequence enabling all `traits` set in the
    /// option set. Caller pairs with `reset` (or another sequence
    /// that resets) once the styled span ends. ECMA-48 SGR codes:
    /// 1=bold, 2=dim, 3=italic, 4=underline, 7=inverse, 9=strikethrough.
    public static func traits(_ traits: TextTraits) -> String {
        guard !traits.isEmpty else { return "" }
        var codes: [Int] = []
        if traits.contains(.bold)          { codes.append(1) }
        if traits.contains(.dim)           { codes.append(2) }
        if traits.contains(.italic)        { codes.append(3) }
        if traits.contains(.underline)     { codes.append(4) }
        if traits.contains(.inverse)       { codes.append(7) }
        if traits.contains(.strikethrough) { codes.append(9) }
        // Single CSI-prefixed sequence with semicolon-joined params is
        // the most compact form ECMA-48 allows; saves bytes over the
        // wire for runs with multiple traits.
        return "\(csi)\(codes.map(String.init).joined(separator: ";"))m"
    }
}
