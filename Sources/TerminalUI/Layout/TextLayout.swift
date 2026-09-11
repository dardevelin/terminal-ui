// Word-aware line wrapping — the shared text-layout primitive.
//
// Mirrors SwiftUI / CoreText's `kCTLineBreakByWordWrapping`, the
// default break mode for Apple's `Text` (per the wrap research
// 2026-04-25 saved to `reference_swiftui_observation_research.md`)
// and the behaviour Apple HIG prescribes for "text view"
// content (`apple-hig/components/text-fields.md` §"Adjust line breaks
// according to field needs"):
//
//   "Default behavior: System clips text extending beyond field
//    bounds. Alternatives: Wrap text to new line at character or
//    word level; truncate with ellipsis at beginning, middle, or
//    end."
//
// Word level wrap is the reading-friendly default for any view
// holding "larger amounts of text" — TextArea, PromptInput, and any
// long-content `Text`. Single-line `TextInput` keeps the
// character-clip default per HIG.
//
// Algorithm: tokenise into runs of (non-space) and (space) tokens,
// then pack tokens into ≤`width` chunks. A word longer than `width`
// (URLs, identifiers) hard-breaks at character level so it remains
// visible; a boundary space is dropped where wrapping forces a new
// chunk so wrapped lines don't start with a stray leading space.
/// Namespace for the shared text-layout primitives — word-aware wrapping
/// used by `Text`, ``TextArea``, and ``PromptInput``.
public enum TextLayout {

    /// Wraps `line` into chunks of ≤`width` cells, preferring
    /// whitespace boundaries. Empty input yields one empty chunk so
    /// the row remains navigable. `width <= 0` returns `[line]`
    /// unchanged (no-wrap).
    ///
    /// Reassembly contract: `chunks.joined()` reproduces the source
    /// EXACTLY for spaceless input. For input with spaces, at most
    /// one space per wrap boundary may be dropped; the non-space
    /// character sequence always reproduces the source.
    public static func wrapWords(_ line: String, width: Int) -> [String] {
        guard width > 0 else { return [line] }
        if line.isEmpty { return [""] }
        // Pure-character path for spaceless input (URLs, identifiers,
        // paste-bombed tokens). Reassembles exactly.
        if !line.contains(" ") {
            return charStrideChunks(line, width: width)
        }

        var chunks: [String] = []
        var current = ""
        var currentWidth = 0
        var i = line.startIndex
        while i < line.endIndex {
            // Tokenise: a maximal run of non-space OR a maximal run
            // of space. Spaces are kept as their own tokens so
            // trailing/leading spaces inside the line are preserved
            // when they fit, and dropped only at wrap boundaries.
            let isSpace = line[i] == " "
            var j = i
            while j < line.endIndex && (line[j] == " ") == isSpace {
                j = line.index(after: j)
            }
            let token = String(line[i..<j])
            let tokenWidth = token.displayWidth
            i = j

            // Long word: flush current and hard-break at char level.
            // displayWidth means CJK / emoji measure correctly.
            if tokenWidth > width {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                    currentWidth = 0
                }
                chunks.append(contentsOf: charStrideChunks(token, width: width))
                continue
            }

            if currentWidth + tokenWidth <= width {
                current += token
                currentWidth += tokenWidth
            } else {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                    currentWidth = 0
                }
                if token.first == " " {
                    // Pure-space token at a wrap boundary — drop it
                    // so the new chunk starts cleanly.
                    continue
                }
                current = token
                currentWidth = tokenWidth
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        if chunks.isEmpty {
            chunks.append("")
        }
        return chunks
    }

    /// Slice `s` into chunks each ≤`width` cells. Used as a fallback
    /// for tokens longer than `width` and for spaceless input.
    /// Reassembly is exact (every character lands in exactly one chunk).
    /// CJK / emoji are measured as 2 cells per grapheme; combining
    /// marks as 0 cells. A 2-cell character at a chunk boundary moves
    /// to the next chunk rather than overflowing.
    public static func charStrideChunks(_ s: String, width: Int) -> [String] {
        guard width > 0 else { return [s] }
        var out: [String] = []
        var current = ""
        var currentWidth = 0
        for ch in s {
            let w = ch.displayWidth
            if currentWidth + w > width && !current.isEmpty {
                out.append(current)
                current = ""
                currentWidth = 0
            }
            current.append(ch)
            currentWidth += w
        }
        if !current.isEmpty {
            out.append(current)
        }
        return out.isEmpty ? [""] : out
    }
}

// MARK: - Span-aware truncation

extension TextLayout {

    /// Shorten a styled run list to `width` cells, marking the elision with
    /// `…` and preserving each surviving span's own style.
    ///
    /// The string-level twin is ``LineBreakMode/apply(to:width:)``; a status
    /// row like `● gopls  not started` is a span list, not a string, so
    /// truncating it through the string path would flatten three colors into
    /// one. Cutting is display-width aware for the same reason wrapping is —
    /// a 2-cell ideograph at the boundary is dropped whole rather than
    /// leaving half a cell.
    ///
    /// The ellipsis inherits the style of the span it interrupts, so a cut
    /// through dim trailing detail stays dim rather than jumping to the
    /// color of whichever run happened to come first.
    public static func truncate(
        _ spans: [TextSpan],
        width: Int,
        edge: TextTruncationEdge
    ) -> [TextSpan] {
        guard width > 0 else { return [] }
        let total = spans.reduce(0) { $0 + $1.text.displayWidth }
        guard total > width else { return spans }
        // No room for anything but the marker itself.
        guard width > 1 else {
            return [TextSpan("…", copyingStyleOf: spans.first)]
        }

        switch edge {
        case .tail:
            return prefix(spans, width: width - 1) + [ellipsis(spans, at: width - 1)]
        case .head:
            return [ellipsis(spans, at: total - (width - 1))] + suffix(spans, width: width - 1)
        case .middle:
            // Odd remainders give the extra cell to the head, matching
            // `LineBreakMode.byTruncatingMiddle`.
            let room = width - 1
            let headWidth = (room + 1) / 2
            return prefix(spans, width: headWidth)
                + [ellipsis(spans, at: headWidth)]
                + suffix(spans, width: room - headWidth)
        }
    }

    /// The leading `width` cells of `spans`, cutting the final span mid-run
    /// when the boundary falls inside it.
    private static func prefix(_ spans: [TextSpan], width: Int) -> [TextSpan] {
        guard width > 0 else { return [] }
        var out: [TextSpan] = []
        var used = 0
        for span in spans {
            let spanWidth = span.text.displayWidth
            if used + spanWidth <= width {
                out.append(span)
                used += spanWidth
                if used == width { break }
                continue
            }
            var kept = ""
            for character in span.text {
                let cellWidth = character.displayWidth
                if used + cellWidth > width { break }
                kept.append(character)
                used += cellWidth
            }
            if !kept.isEmpty { out.append(span.replacingText(kept)) }
            break
        }
        return out
    }

    /// The trailing `width` cells of `spans`, mirroring ``prefix(_:width:)``.
    private static func suffix(_ spans: [TextSpan], width: Int) -> [TextSpan] {
        guard width > 0 else { return [] }
        var out: [TextSpan] = []
        var used = 0
        for span in spans.reversed() {
            let spanWidth = span.text.displayWidth
            if used + spanWidth <= width {
                out.insert(span, at: 0)
                used += spanWidth
                if used == width { break }
                continue
            }
            var kept = ""
            for character in span.text.reversed() {
                let cellWidth = character.displayWidth
                if used + cellWidth > width { break }
                kept.insert(character, at: kept.startIndex)
                used += cellWidth
            }
            if !kept.isEmpty { out.insert(span.replacingText(kept), at: 0) }
            break
        }
        return out
    }

    /// An `…` span wearing the style of whichever span covers cell `offset`,
    /// which is the run the cut passes through.
    private static func ellipsis(_ spans: [TextSpan], at offset: Int) -> TextSpan {
        var seen = 0
        for span in spans {
            seen += span.text.displayWidth
            if seen > offset { return TextSpan("…", copyingStyleOf: span) }
        }
        return TextSpan("…", copyingStyleOf: spans.last)
    }
}

extension TextSpan {
    /// Same styling, different text — used when truncation cuts a run.
    func replacingText(_ newText: String) -> TextSpan {
        TextSpan(newText, foreground: foreground, background: background,
                 bold: bold, italic: italic, underline: underline)
    }

    /// A span carrying `text` with `source`'s styling (unstyled if nil).
    init(_ text: String, copyingStyleOf source: TextSpan?) {
        self.init(text,
                  foreground: source?.foreground, background: source?.background,
                  bold: source?.bold, italic: source?.italic, underline: source?.underline)
    }
}

// MARK: - Span-aware wrapping

extension TextLayout {

    /// Wrap a styled run list into rows of at most `width` cells, breaking at
    /// whitespace like ``wrapWords(_:width:)`` does for a plain string.
    ///
    /// The string twin is not enough on its own: a paragraph carrying any
    /// styling at all is a run list, and re-joining it to wrap would throw
    /// away which characters were bold or coloured. Breaking per character
    /// instead — which is what a naive cell-by-cell writer does — reflows the
    /// same sentence differently depending on whether part of it happens to be
    /// emphasised, and disagrees with the measurer, which counts word-wrapped
    /// rows for styled and unstyled text alike.
    ///
    /// Embedded newlines start a new row. A word longer than `width` breaks at
    /// a character boundary so it stays visible rather than vanishing.
    /// `width <= 0` returns the input as a single row.
    public static func wrap(_ spans: [TextSpan], width: Int) -> [[TextSpan]] {
        guard width > 0 else { return [spans] }

        // Characters carry their span index so style survives regrouping.
        var characters: [(character: Character, span: Int)] = []
        for (index, span) in spans.enumerated() {
            for character in span.text {
                characters.append((character, index))
            }
        }
        guard !characters.isEmpty else { return [[]] }

        var rows: [[(Character, Int)]] = []
        var row: [(Character, Int)] = []
        var used = 0
        var index = 0
        // Only a break the wrapper itself introduced swallows the space at the
        // boundary. Leading whitespace the caller wrote — an indent, a padded
        // list marker — is content and must survive.
        var justWrapped = false

        func endRow(wrapped: Bool) {
            rows.append(row)
            row = []
            used = 0
            justWrapped = wrapped
        }

        while index < characters.count {
            if characters[index].character == "\n" {
                endRow(wrapped: false)
                index += 1
                continue
            }

            // Take the next token — a run of spaces, or a run of non-spaces.
            let isSpace = characters[index].character.isWhitespace
            var token: [(Character, Int)] = []
            var tokenWidth = 0
            while index < characters.count,
                  characters[index].character != "\n",
                  characters[index].character.isWhitespace == isSpace {
                token.append((characters[index].character, characters[index].span))
                tokenWidth += characters[index].character.displayWidth
                index += 1
            }

            if isSpace {
                // A space run that opens a row only because the wrapper broke
                // there is dropped; one the caller wrote is kept.
                if justWrapped && used == 0 {
                    justWrapped = false
                    continue
                }
                if used + tokenWidth <= width {
                    row.append(contentsOf: token)
                    used += tokenWidth
                }
                continue
            }
            justWrapped = false

            if used + tokenWidth <= width {
                row.append(contentsOf: token)
                used += tokenWidth
                continue
            }

            if used > 0 { endRow(wrapped: true) }

            // A word wider than the whole column has to break somewhere; a
            // character boundary keeps it visible, which beats dropping it.
            for cell in token {
                let cellWidth = cell.0.displayWidth
                if used + cellWidth > width, used > 0 { endRow(wrapped: true) }
                row.append(cell)
                used += cellWidth
            }
        }
        endRow(wrapped: false)

        return rows.map { regroup($0, from: spans) }
    }

    /// Rebuild spans from characters, merging neighbours that came from the
    /// same original run so a wrapped row carries no more spans than it needs.
    private static func regroup(_ cells: [(Character, Int)], from spans: [TextSpan]) -> [TextSpan] {
        var out: [TextSpan] = []
        var text = ""
        var current: Int?

        func flush() {
            guard let index = current, !text.isEmpty else { return }
            out.append(spans[index].replacingText(text))
            text = ""
        }

        for (character, index) in cells {
            if index != current {
                flush()
                current = index
            }
            text.append(character)
        }
        flush()
        return out
    }
}
