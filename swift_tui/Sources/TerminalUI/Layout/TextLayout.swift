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
            i = j

            // Long word: flush current and hard-break at char level.
            if token.count > width {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: charStrideChunks(token, width: width))
                continue
            }

            if current.count + token.count <= width {
                current += token
            } else {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                if token.first == " " {
                    // Pure-space token at a wrap boundary — drop it
                    // so the new chunk starts cleanly.
                    continue
                }
                current = token
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

    /// Slice `s` into ≤`width`-character chunks at character level.
    /// Used as a fallback for tokens longer than `width` and for
    /// spaceless input. Reassembly is exact.
    public static func charStrideChunks(_ s: String, width: Int) -> [String] {
        guard width > 0 else { return [s] }
        var out: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: width, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[idx..<end]))
            idx = end
        }
        return out.isEmpty ? [""] : out
    }
}
