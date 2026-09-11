// A CommonMark subset, parsed to values.
//
// Scope is set by what a coding agent's output actually contains: headings,
// paragraphs, fenced code, bullet and ordered lists, block quotes, thematic
// breaks, and inline emphasis / code / links. Deliberately absent are HTML
// blocks, reference links, setext headings, and images — none of them survive
// a cell grid usefully, and every one of them costs parser surface that would
// then need testing.
//
// The parse is a value tree with no styling in it. Rendering lives in
// `MarkdownView`, which is what lets the whole grammar be tested without a
// buffer, and what would let a future caller walk the tree for something other
// than display.
//
// Where this departs from CommonMark it does so knowingly, and
// `MarkdownInline` documents the one case that matters (emphasis flanking).

/// A block-level element.
public enum MarkdownBlock: Equatable, Sendable {
    /// `# Heading`, levels 1–6.
    case heading(level: Int, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    /// A fenced block. `language` is the info string after the opening fence,
    /// lowercased and trimmed, or nil when the fence carried none.
    case codeBlock(language: String?, lines: [String])
    case bulletList([MarkdownListItem])
    /// `start` is the first marker's number, so `3.` renders as 3.
    case orderedList(start: Int, items: [MarkdownListItem])
    case blockQuote([MarkdownBlock])
    /// `---`, `***`, `___`.
    case thematicBreak
}

/// One item of a list. Holds blocks rather than inlines so an item can carry a
/// nested list or a code block, which agent output routinely does.
public struct MarkdownListItem: Equatable, Sendable {
    public let blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }
}

/// Entry point for parsing.
public enum Markdown {

    /// Parse `source` into blocks.
    ///
    /// Never fails: anything the grammar does not recognise stays as paragraph
    /// text, which is the behaviour a chat transcript needs — a malformed
    /// fence should show its content, not swallow the rest of the message.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // A trailing newline produces one empty line that means nothing.
        if lines.last == "" { lines.removeLast() }
        var cursor = 0
        return parseBlocks(lines, &cursor, stopAtListIndent: nil)
    }

    // MARK: - Block parsing

    /// Parse until the lines run out, or — when `stopAtListIndent` is set —
    /// until a line appears that is not indented far enough to belong to the
    /// list item being built.
    private static func parseBlocks(
        _ lines: [String],
        _ cursor: inout Int,
        stopAtListIndent: Int?
    ) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []

        while cursor < lines.count {
            let line = lines[cursor]

            if line.trimmed.isEmpty {
                cursor += 1
                continue
            }

            if let required = stopAtListIndent, indentWidth(line) < required {
                // Belongs to an enclosing block, not this item.
                break
            }

            let body = stopAtListIndent.map { String(line.dropFirst(min($0, indentWidth(line)))) } ?? line

            if let block = parseThematicBreak(body) {
                blocks.append(block)
                cursor += 1
                continue
            }
            if let block = parseHeading(body) {
                blocks.append(block)
                cursor += 1
                continue
            }
            if isFence(body) {
                blocks.append(parseCodeBlock(lines, &cursor, stripping: stopAtListIndent ?? 0))
                continue
            }
            if isBlockQuote(body) {
                blocks.append(parseBlockQuote(lines, &cursor, stripping: stopAtListIndent ?? 0))
                continue
            }
            if listMarker(body) != nil {
                blocks.append(parseList(lines, &cursor, baseIndent: stopAtListIndent ?? 0))
                continue
            }
            blocks.append(parseParagraph(lines, &cursor, stripping: stopAtListIndent ?? 0))
        }

        return blocks
    }

    private static func parseThematicBreak(_ line: String) -> MarkdownBlock? {
        let squashed = line.trimmed.filter { !$0.isWhitespace }
        guard squashed.count >= 3 else { return nil }
        for glyph: Character in ["-", "*", "_"] where squashed.allSatisfy({ $0 == glyph }) {
            return .thematicBreak
        }
        return nil
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmed
        var level = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#", level < 6 {
            level += 1
            index = trimmed.index(after: index)
        }
        // `#hashtag` is not a heading — ATX requires a space after the run.
        guard level > 0, index < trimmed.endIndex, trimmed[index] == " " else { return nil }
        let text = String(trimmed[index...]).trimmed
        return .heading(level: level, content: MarkdownInline.parse(text))
    }

    private static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmed
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func parseCodeBlock(
        _ lines: [String],
        _ cursor: inout Int,
        stripping indent: Int
    ) -> MarkdownBlock {
        let opening = strip(lines[cursor], indent).trimmed
        let fence = String(opening.prefix(3))
        let info = String(opening.dropFirst(3)).trimmed.lowercased()
        cursor += 1

        var body: [String] = []
        while cursor < lines.count {
            let line = strip(lines[cursor], indent)
            if line.trimmed.hasPrefix(fence) {
                cursor += 1
                // An unterminated fence runs to the end of input rather than
                // discarding what it held; a truncated stream is the normal
                // case when an agent is still typing.
                return .codeBlock(language: info.isEmpty ? nil : info, lines: body)
            }
            body.append(line)
            cursor += 1
        }
        return .codeBlock(language: info.isEmpty ? nil : info, lines: body)
    }

    private static func isBlockQuote(_ line: String) -> Bool {
        line.trimmed.hasPrefix(">")
    }

    private static func parseBlockQuote(
        _ lines: [String],
        _ cursor: inout Int,
        stripping indent: Int
    ) -> MarkdownBlock {
        var quoted: [String] = []
        while cursor < lines.count {
            let line = strip(lines[cursor], indent)
            guard isBlockQuote(line) else {
                // A blank line ends the quote; anything else is lazy
                // continuation and stays inside it.
                if line.trimmed.isEmpty { break }
                quoted.append(line)
                cursor += 1
                continue
            }
            var inner = line.trimmed
            inner.removeFirst()
            if inner.hasPrefix(" ") { inner.removeFirst() }
            quoted.append(inner)
            cursor += 1
        }
        var innerCursor = 0
        return .blockQuote(parseBlocks(quoted, &innerCursor, stopAtListIndent: nil))
    }

    /// The marker at the head of a list item, if the line starts one.
    private static func listMarker(_ line: String) -> (ordered: Bool, number: Int, width: Int)? {
        let trimmed = line.trimmed
        guard let first = trimmed.first else { return nil }
        let leading = indentWidth(line)

        if first == "-" || first == "*" || first == "+" {
            let rest = trimmed.dropFirst()
            guard rest.first == " " else { return nil }
            return (false, 0, leading + 2)
        }

        var digits = ""
        for character in trimmed {
            guard character.isNumber else { break }
            digits.append(character)
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return (true, number, leading + digits.count + 2)
    }

    private static func parseList(
        _ lines: [String],
        _ cursor: inout Int,
        baseIndent: Int
    ) -> MarkdownBlock {
        let first = listMarker(strip(lines[cursor], baseIndent))!
        let ordered = first.ordered
        var items: [MarkdownListItem] = []

        while cursor < lines.count {
            let raw = strip(lines[cursor], baseIndent)
            if raw.trimmed.isEmpty {
                // A blank line may separate items or end the list; look ahead.
                let next = cursor + 1
                guard next < lines.count,
                      listMarker(strip(lines[next], baseIndent)) != nil else { break }
                cursor += 1
                continue
            }
            guard let marker = listMarker(raw), marker.ordered == ordered else { break }

            // The item's content starts after the marker; continuation lines
            // belong to it while they stay indented at least that far.
            let contentIndent = marker.width
            var itemLines: [String] = [String(raw.dropFirst(min(contentIndent, raw.count)))]
            cursor += 1
            while cursor < lines.count {
                let candidate = strip(lines[cursor], baseIndent)
                if candidate.trimmed.isEmpty {
                    let next = cursor + 1
                    guard next < lines.count,
                          indentWidth(strip(lines[next], baseIndent)) >= contentIndent else { break }
                    itemLines.append("")
                    cursor += 1
                    continue
                }
                guard indentWidth(candidate) >= contentIndent else { break }
                itemLines.append(String(candidate.dropFirst(contentIndent)))
                cursor += 1
            }

            var itemCursor = 0
            items.append(MarkdownListItem(
                blocks: parseBlocks(itemLines, &itemCursor, stopAtListIndent: nil)))
        }

        return ordered ? .orderedList(start: first.number, items: items) : .bulletList(items)
    }

    private static func parseParagraph(
        _ lines: [String],
        _ cursor: inout Int,
        stripping indent: Int
    ) -> MarkdownBlock {
        var collected: [String] = []
        while cursor < lines.count {
            let line = strip(lines[cursor], indent)
            if line.trimmed.isEmpty { break }
            // A paragraph ends where any other block begins — otherwise a list
            // written directly under a sentence is swallowed into it.
            if !collected.isEmpty,
               parseThematicBreak(line) != nil || parseHeading(line) != nil
                || isFence(line) || isBlockQuote(line) || listMarker(line) != nil {
                break
            }
            collected.append(line.trimmed)
            cursor += 1
        }
        return .paragraph(MarkdownInline.parse(collected.joined(separator: " ")))
    }

    // MARK: - Helpers

    /// Columns of leading whitespace, counting a tab as four.
    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 }
            else if character == "\t" { width += Self.tabWidth }
            else { break }
        }
        return width
    }

    /// Tabs are four columns here, matching how the rest of the framework
    /// lays out text rather than CommonMark's tab stops.
    private static let tabWidth = 4

    /// Drop up to `count` columns of leading whitespace.
    private static func strip(_ line: String, _ count: Int) -> String {
        guard count > 0 else { return line }
        var remaining = count
        var index = line.startIndex
        while index < line.endIndex, remaining > 0 {
            if line[index] == " " { remaining -= 1 }
            else if line[index] == "\t" { remaining -= Self.tabWidth }
            else { break }
            index = line.index(after: index)
        }
        return String(line[index...])
    }
}

extension String {
    var trimmed: String {
        var view = Substring(self)
        while let first = view.first, first.isWhitespace { view = view.dropFirst() }
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }
}
