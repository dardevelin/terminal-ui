// Unicode display-width helpers.
//
// A terminal's screen is a grid of fixed-width cells. A grapheme cluster
// (Swift `Character`) can occupy 0, 1, or 2 cells depending on its
// Unicode properties:
//
//   - East Asian Wide / Fullwidth: 2 cells (CJK ideographs, fullwidth ASCII)
//   - Emoji presentation: 2 cells (most pictographs)
//   - Combining marks, ZWJ, default-ignorable: 0 cells (composed onto base)
//   - Everything else: 1 cell
//
// The framework previously assumed 1 Character == 1 cell, which broke
// alignment, cursor positioning, hit-testing, and diff rendering for any
// non-ASCII content. This module is the cross-cutting fix: writers and
// measurers consult `displayWidth` instead of `.count`, and CellBuffer
// records continuation cells (`Cell.continuation`) on the trailing column
// of a 2-wide character so diff/cursor logic can skip past them.
//
// The width tables here cover the major double-width ranges. Exhaustive
// coverage of every Unicode code point is impractical without committing
// the full UCD; the ranges below match the public ECMA TR 11 / Unicode
// Standard Annex 11 east-asian-width "W" and "F" property values that
// account for >99% of double-width content in practice. Fall through to
// 1 for anything not explicitly listed.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension Character {
    /// Number of terminal cells this grapheme cluster occupies.
    ///
    /// 0 = combining mark / zero-width (rendered onto the previous cell)
    /// 1 = ASCII / Latin / most BMP scripts
    /// 2 = CJK ideographs, fullwidth forms, most emoji
    public var displayWidth: Int {
        // Fast path: pure ASCII (excluding C0/C1 control characters which
        // are 0-width when written but the framework writes them as cells
        // anyway — caller responsibility to filter beforehand).
        if let scalar = unicodeScalars.first,
           unicodeScalars.count == 1,
           scalar.value < 0x80 {
            return scalar.value < 0x20 || scalar.value == 0x7F ? 0 : 1
        }

        // ZWJ sequences (👨‍👩‍👧, family-of-three): the *cluster* is one
        // grapheme rendering as two cells. Detect by looking for an emoji
        // base + zero-width joiner anywhere in the scalar sequence.
        if isEmojiCluster {
            return 2
        }

        // Inspect the first non-combining scalar. If it falls in a
        // double-width range, this cluster is 2 cells. Combining marks
        // attached to a base inherit the base's width.
        guard let base = unicodeScalars.first(where: { !$0.properties.isJoinControl }) else {
            return 0
        }
        return Self.scalarWidth(base.value)
    }

    /// Heuristic — true if this cluster contains at least one default-emoji
    /// scalar in plane 1. Plane-0 dingbats (e.g. U+276F ❯) are emoji-eligible
    /// but render as text by default in monospace terminals, so we treat
    /// them as 1-cell. ZWJ families are detected here so the cluster reports
    /// as a single double-wide unit instead of summing its components.
    private var isEmojiCluster: Bool {
        for scalar in unicodeScalars {
            let v = scalar.value
            // Plane 1 emoji blocks — the Unicode Standard's
            // Emoji_Presentation default-true region. Limited to plane 1
            // intentionally so plane-0 symbols (U+2600..U+27BF dingbats,
            // arrows, etc.) keep their text-presentation 1-cell width.
            if v >= 0x1F300 && v <= 0x1FAFF { return true }
            if v >= 0x1F000 && v <= 0x1F2FF { return true }
        }
        return false
    }

    /// Scalar-level width lookup. Returns 0/1/2 for the given Unicode value.
    /// Tables match Unicode Standard Annex 11 east-asian-width W/F properties.
    static func scalarWidth(_ value: UInt32) -> Int {
        // Fullwidth / wide ranges (UAX #11 properties "W" and "F")
        if value >= 0x1100 && value <= 0x115F { return 2 } // Hangul Jamo
        if value >= 0x2329 && value <= 0x232A { return 2 } // angle brackets
        if value >= 0x2E80 && value <= 0x303E { return 2 } // CJK Radicals + symbols
        if value >= 0x3041 && value <= 0x33FF { return 2 } // Hiragana, Katakana, Bopomofo, CJK
        if value >= 0x3400 && value <= 0x4DBF { return 2 } // CJK Unified Ideographs Ext A
        if value >= 0x4E00 && value <= 0x9FFF { return 2 } // CJK Unified Ideographs
        if value >= 0xA000 && value <= 0xA4CF { return 2 } // Yi
        if value >= 0xAC00 && value <= 0xD7A3 { return 2 } // Hangul Syllables
        if value >= 0xF900 && value <= 0xFAFF { return 2 } // CJK Compatibility Ideographs
        if value >= 0xFE30 && value <= 0xFE4F { return 2 } // CJK Compatibility Forms
        if value >= 0xFF00 && value <= 0xFF60 { return 2 } // Fullwidth Forms
        if value >= 0xFFE0 && value <= 0xFFE6 { return 2 } // Fullwidth signs
        if value >= 0x1F300 && value <= 0x1FAFF { return 2 } // emoji blocks (plane 1)
        if value >= 0x1F000 && value <= 0x1F2FF { return 2 } // mahjong/domino/playing cards
        if value >= 0x20000 && value <= 0x2FFFD { return 2 } // CJK Ext B-F
        if value >= 0x30000 && value <= 0x3FFFD { return 2 } // CJK Ext G

        // Combining marks + zero-width
        if value >= 0x0300 && value <= 0x036F { return 0 } // Combining Diacritical Marks
        if value >= 0x200B && value <= 0x200F { return 0 } // ZW spaces / directional
        if value == 0x200D { return 0 } // ZWJ
        if value >= 0xFE00 && value <= 0xFE0F { return 0 } // Variation selectors
        if value >= 0x180B && value <= 0x180D { return 0 } // Mongolian variation
        if value >= 0x1AB0 && value <= 0x1AFF { return 0 } // Combining Ext
        if value >= 0x1DC0 && value <= 0x1DFF { return 0 } // Combining Supplement
        if value >= 0x20D0 && value <= 0x20FF { return 0 } // Combining for Symbols

        return 1
    }
}

extension StringProtocol {
    /// Total terminal cell count for this string. Sums `Character.displayWidth`
    /// over all grapheme clusters.
    public var displayWidth: Int {
        var total = 0
        for ch in self {
            total += ch.displayWidth
        }
        return total
    }
}
