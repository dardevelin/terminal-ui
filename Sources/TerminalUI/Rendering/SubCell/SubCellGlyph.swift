// HYP-298 — Sub-cell glyph atlas. Maps glyph-class enum cases to
// canonical Unicode "Block Elements" code points (U+2580..U+259F),
// braille (U+2800..U+28FF), and shade glyphs (U+2591..U+2593).
//
// The framework's `Cell` type carries one `Character`; SubCellGlyph
// is the typed source of those characters when sub-cell precision is
// needed. Exhaustive switch over cases means adding a new glyph
// class produces a compile error here, not silent breakage in the
// renderer.

/// Glyphs that approximate sub-cell geometry inside a single
/// terminal cell.
public enum SubCellGlyph: Sendable, Equatable {
    /// Full-cell solid block (U+2588 █).
    case full

    /// Upper half (U+2580 ▀).
    case halfTop

    /// Lower half (U+2584 ▄).
    case halfBottom

    /// Left half (U+258C ▌).
    case halfLeft

    /// Right half (U+2590 ▐).
    case halfRight

    /// 2×2 quadrant pattern. Each set bit lights one corner.
    case quadrant(QuadrantMask)

    /// Vertical fill from the bottom in eighths (U+2581..U+2588).
    case eighthVertical(EighthMask)

    /// 2×4 braille dot grid (U+2800..U+28FF). The framework's
    /// `BrailleCanvas` uses the same code-point math.
    case braille(BrailleDots)

    /// Three pre-defined shade levels (U+2591 ░ / U+2592 ▒ / U+2593 ▓).
    case shade(ShadeLevel)

    /// The Unicode character this glyph case renders as. The
    /// switch is exhaustive so adding a new case requires updating
    /// this method — that's the design.
    public var character: Character {
        switch self {
        case .full: return "█"
        case .halfTop: return "▀"
        case .halfBottom: return "▄"
        case .halfLeft: return "▌"
        case .halfRight: return "▐"
        case .quadrant(let mask): return mask.character
        case .eighthVertical(let level): return level.verticalCharacter
        case .braille(let dots): return dots.character
        case .shade(let level): return level.character
        }
    }
}

// MARK: - QuadrantMask

/// Bitmask of which 2×2 quadrants are lit. Maps to U+2580..U+259F
/// "Block Elements" — there are exactly 16 patterns and Unicode
/// reserves a code point for each.
public struct QuadrantMask: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let topLeft     = QuadrantMask(rawValue: 1 << 0)
    public static let topRight    = QuadrantMask(rawValue: 1 << 1)
    public static let bottomLeft  = QuadrantMask(rawValue: 1 << 2)
    public static let bottomRight = QuadrantMask(rawValue: 1 << 3)

    /// All four quadrants lit (== full block).
    public static let all: QuadrantMask = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    /// Canonical Unicode mapping for this quadrant pattern.
    /// Reference: Unicode 7.0 added the missing quadrant patterns
    /// to U+2580..U+259F so every 4-bit combination has a glyph.
    var character: Character {
        // Patterns are described as TL TR BL BR.
        switch (contains(.topLeft), contains(.topRight), contains(.bottomLeft), contains(.bottomRight)) {
        case (false, false, false, false): return " "
        case (true,  false, false, false): return "▘"  // U+2598
        case (false, true,  false, false): return "▝"  // U+259D
        case (false, false, true,  false): return "▖"  // U+2596
        case (false, false, false, true ): return "▗"  // U+2597
        case (true,  true,  false, false): return "▀"  // U+2580 (top half)
        case (false, false, true,  true ): return "▄"  // U+2584 (bottom half)
        case (true,  false, true,  false): return "▌"  // U+258C (left half)
        case (false, true,  false, true ): return "▐"  // U+2590 (right half)
        case (true,  false, false, true ): return "▚"  // U+259A (diagonal TL+BR)
        case (false, true,  true,  false): return "▞"  // U+259E (anti-diagonal TR+BL)
        case (true,  true,  true,  false): return "▛"  // U+259B
        case (true,  true,  false, true ): return "▜"  // U+259C
        case (true,  false, true,  true ): return "▙"  // U+2599
        case (false, true,  true,  true ): return "▟"  // U+259F
        case (true,  true,  true,  true ): return "█"  // U+2588 (all four = full)
        }
    }
}

// MARK: - EighthMask

/// Eighth-fraction fill level, used for vertical and horizontal
/// progressive-fill glyphs. Each level maps to a distinct Unicode
/// code point.
public enum EighthMask: Sendable, Equatable, Hashable {
    case zero
    case oneEighth
    case twoEighths
    case threeEighths
    case fourEighths
    case fiveEighths
    case sixEighths
    case sevenEighths
    case eightEighths

    /// Vertical fill from bottom (U+2581..U+2588).
    var verticalCharacter: Character {
        switch self {
        case .zero: return " "
        case .oneEighth: return "▁"
        case .twoEighths: return "▂"
        case .threeEighths: return "▃"
        case .fourEighths: return "▄"
        case .fiveEighths: return "▅"
        case .sixEighths: return "▆"
        case .sevenEighths: return "▇"
        case .eightEighths: return "█"
        }
    }
}

// MARK: - BrailleDots

/// 8-dot braille pattern (U+2800..U+28FF). Dot numbering follows the
/// canonical braille convention — same as `BrailleCanvas`'s existing
/// encoding.
///
///   1 4
///   2 5
///   3 6
///   7 8
public struct BrailleDots: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let dot1 = BrailleDots(rawValue: 1 << 0)
    public static let dot2 = BrailleDots(rawValue: 1 << 1)
    public static let dot3 = BrailleDots(rawValue: 1 << 2)
    public static let dot4 = BrailleDots(rawValue: 1 << 3)
    public static let dot5 = BrailleDots(rawValue: 1 << 4)
    public static let dot6 = BrailleDots(rawValue: 1 << 5)
    public static let dot7 = BrailleDots(rawValue: 1 << 6)
    public static let dot8 = BrailleDots(rawValue: 1 << 7)

    /// Unicode code point for this dot pattern.
    /// Base U+2800 plus the rawValue bitmask gives every 256-pattern.
    var character: Character {
        let scalar = Unicode.Scalar(0x2800 + UInt32(rawValue)) ?? Unicode.Scalar(0x2800)!
        return Character(scalar)
    }
}

// MARK: - ShadeLevel

/// Three pre-defined shade glyphs (U+2591 ░ / U+2592 ▒ / U+2593 ▓).
/// Separate from EighthMask because shades imply uniform partial
/// fill, not directional fill.
public enum ShadeLevel: Sendable, Equatable, Hashable {
    case light    // U+2591 ░ ~25% coverage
    case medium   // U+2592 ▒ ~50% coverage
    case dark     // U+2593 ▓ ~75% coverage

    var character: Character {
        switch self {
        case .light: return "░"
        case .medium: return "▒"
        case .dark: return "▓"
        }
    }
}
