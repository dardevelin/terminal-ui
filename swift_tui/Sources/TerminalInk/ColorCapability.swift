#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// HYP-56 / HYP-13 — terminal color-tier detection and downgrade.
//
// Detection precedence (highest wins):
//
//   1. NO_COLOR env var set (any value, including empty) → none.
//      Per https://no-color.org — "When present, regardless of its
//      value, this environment variable prevents the addition of ANSI
//      color." Universal opt-out.
//   2. isatty(1) is false → none. Output is piped or redirected;
//      injecting escape sequences would corrupt the consumer.
//   3. COLORTERM == "truecolor" or "24bit" → trueColor. The de facto
//      signal that a terminal supports 24-bit RGB.
//   4. TERM contains "256color" → ansi256.
//   5. Otherwise → basic16. Conservative fallback that works on
//      every terminal back to vt100 + xterm extensions.

/// The color tier the active terminal supports.
public enum ColorCapability: Sendable, Hashable {
    /// Strip color entirely. Output is piped, NO_COLOR is set, or the
    /// runtime explicitly opted out.
    case none
    /// 16-color named palette only — ECMA-48 SGR 30-37 / 90-97.
    case basic16
    /// 256-color extended palette — xterm-256color and friends.
    case ansi256
    /// 24-bit RGB — modern terminal emulators.
    case trueColor

    /// Detect from environment + tty status. Pure function so callers
    /// can override either input for testing or enforce a specific
    /// tier (e.g., a `--color=always` CLI flag overrides isatty).
    public static func detect(env: [String: String], isTTY: Bool) -> ColorCapability {
        // NO_COLOR wins regardless of TTY or COLORTERM. Spec is clear:
        // any value, including empty string, disables color.
        if env["NO_COLOR"] != nil { return .none }
        // Piped output gets stripped — honoring the unwritten rule that
        // tools should detect their own output stream and adapt.
        if !isTTY { return .none }
        // COLORTERM is the truecolor signal modern emulators set.
        if let ct = env["COLORTERM"], ct == "truecolor" || ct == "24bit" {
            return .trueColor
        }
        // TERM holding "256color" promises the extended palette.
        if let term = env["TERM"], term.contains("256color") {
            return .ansi256
        }
        // Conservative fallback. Even tmux + dumb terminals honor 16.
        return .basic16
    }

    /// Detect from process environment + STDOUT_FILENO tty status.
    /// Convenience wrapper around `detect(env:isTTY:)` for runtime
    /// startup. CLIs wanting deterministic behavior under tests should
    /// call the env-injection form directly.
    public static func detectFromProcess() -> ColorCapability {
        let env = ProcessInfo.processInfo.environment
        let tty = isatty(1) != 0
        return detect(env: env, isTTY: tty)
    }

    /// Downgrade `color` to a representation the active capability can
    /// emit faithfully. RGB → ansi256 → named, with `.none` erasing
    /// everything to `.default`.
    ///
    /// Idempotent: passing a `.named(...)` to a `.basic16` cap returns
    /// the same color; passing an `.ansi256(...)` to `.ansi256` ditto.
    public func downgrade(_ color: InkColor) -> InkColor {
        switch self {
        case .none:
            return .default
        case .trueColor:
            return color
        case .ansi256:
            switch color {
            case .default, .named, .ansi256:
                return color
            case .rgb(let r, let g, let b):
                return .ansi256(rgbToAnsi256(r, g, b))
            }
        case .basic16:
            switch color {
            case .default, .named:
                return color
            case .ansi256(let n):
                return .named(ansi256ToNamed(n))
            case .rgb(let r, let g, let b):
                let idx = rgbToAnsi256(r, g, b)
                return .named(ansi256ToNamed(idx))
            }
        }
    }
}

// MARK: - Downgrade primitives
//
// Two operations:
//
//   1. `rgbToAnsi256(r,g,b)` — find the closest of the 256 palette
//      slots. The 256 palette is laid out as:
//
//         0..15    : 16 standard named colors
//         16..231  : 6×6×6 RGB cube (216 colors)
//         232..255 : 24-step grayscale ramp (excluding pure black/white,
//                    which already live in the named slots)
//
//      Strategy: try the cube + grayscale + named-color RGB equivalents,
//      pick the slot with the smallest squared sRGB distance. Mirrors
//      the algorithm in chalk / rich / colorama.
//
//   2. `ansi256ToNamed(n)` — collapse a 256-palette slot to one of the
//      16 named colors. Slots 0-15 are already named. Cube + grayscale
//      collapse via the same nearest-distance match against the 16
//      named-color RGB equivalents.

/// 6-step axis values for the RGB cube. Per xterm's color spec, the
/// step sequence is irregular (not 0, 51, 102, 153, ...) — it's
/// `0, 95, 135, 175, 215, 255`. This array is the reference; do not
/// recompute.
private let cubeSteps: [Int] = [0, 95, 135, 175, 215, 255]

/// Approximate sRGB values for the 16 named-color slots (matches
/// xterm's default palette). Used by both `rgbToAnsi256` (for slots
/// 0-15) and `ansi256ToNamed` (reverse mapping).
private let namedColorRGB: [(NamedColor, Int, Int, Int)] = [
    (.black,         0,   0,   0),
    (.red,           128, 0,   0),
    (.green,         0,   128, 0),
    (.yellow,        128, 128, 0),
    (.blue,          0,   0,   128),
    (.magenta,       128, 0,   128),
    (.cyan,          0,   128, 128),
    (.white,         192, 192, 192),
    (.brightBlack,   128, 128, 128),
    (.brightRed,     255, 0,   0),
    (.brightGreen,   0,   255, 0),
    (.brightYellow,  255, 255, 0),
    (.brightBlue,    0,   0,   255),
    (.brightMagenta, 255, 0,   255),
    (.brightCyan,    0,   255, 255),
    (.brightWhite,   255, 255, 255),
]

/// Squared Euclidean distance in sRGB. Cheap nearest-color metric;
/// LAB / DeltaE would be more perceptually accurate but the entire
/// downgrade table is small enough that the difference rarely matters
/// for terminal palettes.
private func sqDist(_ r1: Int, _ g1: Int, _ b1: Int,
                    _ r2: Int, _ g2: Int, _ b2: Int) -> Int {
    let dr = r1 - r2, dg = g1 - g2, db = b1 - b2
    return dr * dr + dg * dg + db * db
}

/// Map (r, g, b) to the closest of the 256 ANSI palette slots.
///
/// Convention (matches chalk/rich/colorama): we only search the
/// 6×6×6 cube (16..231) and the 24-step grayscale (232..255), NOT
/// the 16 named slots (0..15). The named slots are user-themable —
/// their actual rendered color depends on terminal preferences — so
/// mapping into them produces unpredictable visuals. The cube and
/// grayscale ramp are RGB-stable across terminals.
private func rgbToAnsi256(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
    let ri = Int(r), gi = Int(g), bi = Int(b)
    var bestIdx = 16
    var bestDist = Int.max

    // Slots 16..231 — 6×6×6 RGB cube.
    for ri6 in 0..<6 {
        for gi6 in 0..<6 {
            for bi6 in 0..<6 {
                let cr = cubeSteps[ri6]
                let cg = cubeSteps[gi6]
                let cb = cubeSteps[bi6]
                let d = sqDist(ri, gi, bi, cr, cg, cb)
                if d < bestDist {
                    bestDist = d
                    bestIdx = 16 + 36 * ri6 + 6 * gi6 + bi6
                }
            }
        }
    }

    // Slots 232..255 — grayscale ramp. Each step is 8 + i*10.
    for i in 0..<24 {
        let level = 8 + i * 10
        let d = sqDist(ri, gi, bi, level, level, level)
        if d < bestDist { bestDist = d; bestIdx = 232 + i }
    }

    return UInt8(bestIdx)
}

/// Collapse a 256-palette slot to the nearest of the 16 named colors.
private func ansi256ToNamed(_ n: UInt8) -> NamedColor {
    let idx = Int(n)
    // Slots 0-15 are already named — direct lookup.
    if idx < 16 { return namedColorRGB[idx].0 }

    // Decompose the slot back to RGB so we can re-match against the
    // 16-color palette.
    let r: Int, g: Int, b: Int
    if idx < 232 {
        let n6 = idx - 16
        let ri6 = n6 / 36
        let gi6 = (n6 / 6) % 6
        let bi6 = n6 % 6
        r = cubeSteps[ri6]; g = cubeSteps[gi6]; b = cubeSteps[bi6]
    } else {
        let level = 8 + (idx - 232) * 10
        r = level; g = level; b = level
    }

    var best: NamedColor = .black
    var bestDist = Int.max
    for entry in namedColorRGB {
        let d = sqDist(r, g, b, entry.1, entry.2, entry.3)
        if d < bestDist { bestDist = d; best = entry.0 }
    }
    return best
}
