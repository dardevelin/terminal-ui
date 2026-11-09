import Testing
@testable import TerminalUI

// A terminal gives each code point its UAX #11 East_Asian_Width: W and F
// take two columns. A character the framework counts as one where the
// terminal draws two puts everything after it on its row a column late,
// so these pin the width of the characters that once disagreed, the
// deliberate choices the table makes beyond the file, and the table as a
// whole.

@Suite("Character width follows EastAsianWidth.txt")
struct DisplayWidthTableTests {

    /// Emoji_Presentation characters below U+10000. UAX #11 has given every
    /// Emoji_Presentation character East_Asian_Width W since Unicode 9.0, and
    /// `wcwidth` terminals draw them in two columns with no selector.
    static let wideBMPEmoji: [Character] = [
        "\u{231A}", "\u{231B}", "\u{23E9}", "\u{23F0}", "\u{23F3}", "\u{25FD}",
        "\u{2614}", "\u{2615}", "\u{2648}", "\u{2653}", "\u{267F}", "\u{2693}",
        "\u{26A1}", "\u{26AA}", "\u{26BD}", "\u{26C4}", "\u{26CE}", "\u{26D4}",
        "\u{26EA}", "\u{26F2}", "\u{26F5}", "\u{26FA}", "\u{26FD}", "\u{2705}",
        "\u{270A}", "\u{2728}", "\u{274C}", "\u{274E}", "\u{2753}", "\u{2757}",
        "\u{2795}", "\u{27B0}", "\u{27BF}", "\u{2B1B}", "\u{2B50}", "\u{2B55}",
    ]

    @Test("emoji with emoji presentation below U+10000 are two columns",
          arguments: wideBMPEmoji)
    func wideBMPEmojiAreTwoColumns(_ emoji: Character) {
        #expect(emoji.displayWidth == 2, "U+\(String(emoji.unicodeScalars.first!.value, radix: 16, uppercase: true))")
    }

    @Test("a wide emoji puts what follows it two columns on")
    func textAfterAWideEmoji() {
        #expect("⭐a".displayWidth == 3)
        #expect("⌚ ⌛ ☔".displayWidth == 8)
    }

    @Test("ambiguous-width characters are one column, as outside an East Asian context")
    func ambiguousIsNarrow() {
        // UAX #11 §5: A resolves to narrow unless the context is a legacy
        // East Asian one; terminals draw it narrow unless configured to.
        for character: Character in ["…", "─", "│", "°", "±", "§", "①", "→", "■", "○", "★", "Ω"] {
            #expect(character.displayWidth == 1, "\(character)")
        }
    }

    @Test("text-presentation symbols with no selector are one column")
    func textDefaultSymbolsAreNarrow() {
        // East_Asian_Width N with Emoji_Presentation=No: drawn as text, one
        // column, in plane 0 and plane 1 alike.
        for character: Character in ["❯", "✓", "✔", "❤", "☀", "⚠", "\u{1F321}", "\u{1F5A5}", "\u{1F54A}"] {
            #expect(character.displayWidth == 1, "\(character)")
        }
    }

    @Test("an emoji presentation selector makes a text-default emoji two columns")
    func presentationSelectorWidens() {
        // UTS #51 §1.4.3 ED-9a: an emoji character followed by U+FE0F is an
        // emoji presentation sequence, drawn as an emoji, two columns.
        for character: Character in ["❤\u{FE0F}", "⚠\u{FE0F}", "✔\u{FE0F}", "☀\u{FE0F}",
                                     "\u{1F321}\u{FE0F}", "1\u{FE0F}\u{20E3}", "#\u{FE0F}\u{20E3}",
                                     "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", "❤\u{FE0F}\u{200D}\u{1F525}"] {
            #expect(character.displayWidth == 2, "\(character.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        // A wide emoji stays two; a selector after a letter is no emoji
        // presentation sequence and changes nothing.
        #expect("⭐\u{FE0F}".displayWidth == 2)
        #expect("\u{1F642}\u{FE0F}".displayWidth == 2)
        #expect("a\u{FE0F}".displayWidth == 1)
    }

    @Test("a text presentation selector leaves a wide emoji two columns")
    func textSelectorKeepsWidth() {
        // Most terminals ignore U+FE0E for width; East_Asian_Width W stands.
        #expect("⌚\u{FE0E}".displayWidth == 2)
        #expect("❤\u{FE0E}".displayWidth == 1)
    }

    @Test("CJK, kana, Hangul and fullwidth forms stay two columns")
    func eastAsianWideStays() {
        for character: Character in ["中", "文", "\u{3400}", "\u{20000}", "\u{30000}", "あ", "カ",
                                     "한", "\u{1100}", "Ａ", "！", "￥", "\u{3000}", "〔", "\u{FE30}"] {
            #expect(character.displayWidth == 2, "\(character)")
        }
    }

    @Test("halfwidth forms are one column")
    func halfwidthIsNarrow() {
        for character: Character in ["ｶ", "ｱ", "ﾟ", "￨"] {
            #expect(character.displayWidth == 1, "\(character)")
        }
    }

    @Test("emoji sequences are one two-column glyph")
    func emojiSequences() {
        #expect("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".displayWidth == 2)
        #expect("\u{1F44D}\u{1F3FD}".displayWidth == 2)
        #expect("\u{1F1FA}\u{1F1F8}".displayWidth == 2)
        #expect("\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}".displayWidth == 2)
    }

    @Test("combining marks and zero-width format characters are zero columns")
    func zeroWidth() {
        let marks: [UInt32] = [0x0300, 0x036F, 0x0483, 0x0591, 0x064B, 0x0901, 0x0E31,
                               0x1AB0, 0x1DC0, 0x20D0, 0x20E3, 0x3099, 0xFE00, 0xFE0F, 0xFE20, 0xE0100]
        let ignorableFormat: [UInt32] = [0x061C, 0x200B, 0x200C, 0x200D, 0x200E, 0x202A, 0x2060,
                                         0x2064, 0x2066, 0xFEFF, 0xE0001, 0xE0067, 0xE007F]
        for value in marks + ignorableFormat {
            #expect(Character.scalarWidth(value) == 0, "U+\(String(value, radix: 16, uppercase: true))")
        }
        #expect("e\u{0301}".displayWidth == 1)
        #expect("\u{0301}".displayWidth == 0)
        // Drawn, so not zero: SOFT HYPHEN and a prepended concatenation mark.
        #expect(Character.scalarWidth(0x00AD) == 1)
        #expect(Character.scalarWidth(0x0600) == 1)
    }

    @Test("the table is sorted, disjoint and merged")
    func tableIsWellFormed() {
        let table = Character.scalarWidthRanges
        #expect(!table.isEmpty)
        for (earlier, later) in zip(table, table.dropFirst()) {
            #expect(earlier.first <= earlier.last)
            #expect(earlier.last < later.first, "U+\(String(earlier.last, radix: 16)) overlaps U+\(String(later.first, radix: 16))")
            #expect(earlier.last + 1 < later.first || earlier.width != later.width)
        }
        #expect(table.allSatisfy { $0.width != 1 })
    }

    @Test("every code point in the table's ranges has that range's width")
    func everyCodePointInTheTable() {
        var mismatches: [UInt32] = []
        for range in Character.scalarWidthRanges {
            for value in range.first...range.last where Character.scalarWidth(value) != Int(range.width) {
                mismatches.append(value)
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(8).map { String($0, radix: 16) })")
        #expect(Character.scalarWidthRanges.contains { $0.width == 2 && $0.first <= 0x2B50 && 0x2B50 <= $0.last })
    }

    @Test("every code point between the table's ranges is one column")
    func everyCodePointBetween() {
        var mismatches: [UInt32] = []
        var next: UInt32 = 0x80
        for range in Character.scalarWidthRanges + [ScalarWidthRange(0x110000, 0x110000, 0)] {
            for value in next..<max(next, range.first) where Character.scalarWidth(value) != 1 {
                mismatches.append(value)
            }
            next = range.last + 1
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(8).map { String($0, radix: 16) })")
    }
}
