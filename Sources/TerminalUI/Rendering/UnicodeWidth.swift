// Unicode display-width helpers.
//
// A terminal's screen is a grid of fixed-width cells. A grapheme cluster
// (Swift `Character`) can occupy 0, 1, or 2 cells depending on its
// Unicode properties:
//
//   - East Asian Wide / Fullwidth: 2 cells (CJK ideographs, fullwidth
//     forms, and the Emoji_Presentation characters, which UAX #11 has
//     given W since Unicode 9.0), and the regional indicators of a flag
//   - Combining marks and ignorable format characters: 0 cells (composed
//     onto the base)
//   - Everything else: 1 cell, ambiguous width (A) included
//
// The framework previously assumed 1 Character == 1 cell, which broke
// alignment, cursor positioning, hit-testing, and diff rendering for any
// non-ASCII content. This module is the cross-cutting fix: writers and
// measurers consult `displayWidth` instead of `.count`, and CellBuffer
// marks the trailing column of a 2-wide character as its continuation
// (`Cell.isContinuation`), which the output stage never sends: the
// terminal's cursor already stepped over it.
//
// A terminal advances its cursor by its own count of each code point, so
// this count has to be the one terminals share, not an approximation of
// it: a character counted as 1 that the terminal draws in 2 puts the rest
// of its row a column late. The per-code-point widths are therefore
// generated from EastAsianWidth.txt into `UnicodeWidthTable.swift`, which
// names the Unicode version it came from. `tools/scripts/
// generate_width_table.py` regenerates it by the rules
// `tools/terminalui/width.py` states, with why for each — the rules the
// smoke suite's terminal model counts columns by too.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Terminal-width and control-character classification for grapheme
/// clusters — the cell-count arithmetic every layout measurement rests
/// on.
extension Character {
    /// Whether this is a control character a terminal would act on rather
    /// than draw.
    ///
    /// C0 (U+0000–U+001F) and DEL per ECMA-48 §5.2, plus C1 (U+0080–U+009F),
    /// whose members are single-scalar equivalents of ESC-prefixed sequences
    /// and are executed directly by a terminal in an 8-bit mode.
    ///
    /// `CellBuffer` refuses these rather than storing them: cell bytes are
    /// copied verbatim to the file descriptor, so a stored control would be
    /// executed instead of rendered.
    /// Tests every scalar rather than only single-scalar clusters: `"\r\n"` is
    /// **one** grapheme cluster of two scalars under UAX #29 rule GB3, so a
    /// single-scalar check would pass CR and LF straight through — and CRLF is
    /// ordinary input from a Windows file, an HTTP header, or a CRLF checkout.
    /// Composed glyphs are unaffected: no combining mark, ZWJ sequence, or
    /// regional-indicator pair contains a control scalar.
    var isTerminalControl: Bool {
        unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value)
        }
    }

    /// Number of terminal cells this grapheme cluster occupies.
    ///
    /// 0 = combining mark / zero-width (rendered onto the previous cell)
    /// 1 = ASCII / Latin / most BMP scripts, and ambiguous-width characters
    /// 2 = CJK ideographs, fullwidth forms, emoji
    ///
    /// A cluster is as wide as its first scalar: the marks, selectors,
    /// modifiers and joined emoji after it draw within its cells, so a ZWJ
    /// sequence (👨‍👩‍👧) or a flag is one glyph, not the sum of its parts.
    /// One exception widens it: a text-default emoji followed by U+FE0F.
    public var displayWidth: Int {
        let scalars = unicodeScalars
        // Fast path: pure ASCII. C0 and DEL report 0 here; `CellBuffer`
        // refuses them outright via `isTerminalControl`, so the width is
        // academic for anything that reaches a cell.
        var iterator = scalars.makeIterator()
        guard let first = iterator.next() else { return 0 }
        let second = iterator.next()
        if second == nil, first.isASCII {
            return first.value < 0x20 || first.value == 0x7F ? 0 : 1
        }

        let width = Self.scalarWidth(first.value)
        guard width != 0 else {
            // A cluster that opens with a zero-width scalar — a ZWJ or a mark
            // with no base before it — is as wide as what it carries (a
            // skin-tone modifier after a ZWJ), as a terminal summing code
            // points would draw it.
            return scalars.lazy.map { Self.scalarWidth($0.value) }.first { $0 != 0 } ?? 0
        }
        // UTS #51 §1.4.3 (ED-9a): an emoji character followed by U+FE0F
        // VARIATION SELECTOR-16 is an emoji presentation sequence, drawn as
        // an emoji, in two columns, though the character alone is text and
        // one column (❤ U+2764, ⚠ U+26A0, a keycap's digit). Terminals
        // differ here. Most widen it: kitty, Ghostty, foot, iTerm2, Konsole,
        // Windows Terminal and tmux score full marks on ucs-detect's VS16
        // test, where xterm, VTE, WezTerm and Apple Terminal leave it one
        // column (https://ucs-detect.readthedocs.io/results.html). The
        // width libraries other TUI toolkits measure with widen it too:
        // Rust's unicode-width, Go's uniseg, JavaScript's string-width. U+FE0E
        // VARIATION SELECTOR-15 does not narrow a wide emoji: of those
        // terminals only kitty, Ghostty and foot narrow it, and
        // East_Asian_Width W stands.
        if width == 1, second == Self.emojiPresentationSelector, first.properties.isEmoji {
            return Self.wideGlyphColumns
        }
        return width
    }

    /// U+FE0F VARIATION SELECTOR-16, which requests emoji presentation of
    /// the character before it (UTS #51 §1.4.3).
    private static let emojiPresentationSelector: Unicode.Scalar = "\u{FE0F}"
    private static let wideGlyphColumns = 2

    /// Scalar-level width lookup: 0, 1 or 2 columns for the given Unicode
    /// value, from `scalarWidthRanges` — every code point it does not list
    /// is 1. A binary search over the ranges, skipped below the first of
    /// them, where every code point is 1.
    static func scalarWidth(_ value: UInt32) -> Int {
        let table = scalarWidthRanges
        guard let lowest = table.first, value >= lowest.first else { return 1 }
        var low = 0
        var high = table.count
        while low < high {
            let middle = (low + high) / 2
            let range = table[middle]
            if value < range.first {
                high = middle
            } else if value > range.last {
                low = middle + 1
            } else {
                return Int(range.width)
            }
        }
        return 1
    }
}

/// A run of code points of one terminal width, `first...last` — an entry of
/// the generated `Character.scalarWidthRanges`.
struct ScalarWidthRange: Sendable {
    let first: UInt32
    let last: UInt32
    let width: UInt8

    init(_ first: UInt32, _ last: UInt32, _ width: UInt8) {
        self.first = first
        self.last = last
        self.width = width
    }
}

/// String-level terminal-width measurement over any string slice.
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
