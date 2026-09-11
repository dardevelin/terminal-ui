// Tree → rows.
//
// This is where markdown stops being a document and becomes lines on a grid,
// and where every styling decision is made. Colours come from ``Theme`` roles
// only — no literal ever appears here, which is what lets a markdown message
// restyle with the rest of the app.

enum MarkdownFlattener {

    /// Indentation the renderer applies, in columns. Nested lists take theirs
    /// from the enclosing marker's width rather than a constant, so the text
    /// columns line up however wide the ordinals run.
    private enum Indent {
        /// Code sits in from the prose around it so the fill reads as a block
        /// rather than as a highlight that happens to span the width.
        static let code = 2
    }

    /// Glyphs the renderer draws in the gutter.
    private enum Gutter {
        static let bullet = "• "
        static let rule = "─"
    }

    static func flatten(_ blocks: [MarkdownBlock], theme: any Theme) -> [MarkdownRow] {
        var rows: [MarkdownRow] = []
        emit(blocks, into: &rows, indent: 0, theme: theme, separated: true)
        return rows
    }

    private static func emit(
        _ blocks: [MarkdownBlock],
        into rows: inout [MarkdownRow],
        indent: Int,
        theme: any Theme,
        separated: Bool
    ) {
        for (offset, block) in blocks.enumerated() {
            // A blank line between siblings, never before the first or after
            // the last — leading and trailing gaps are the container's to
            // decide, not the document's. Inside a list item there is no gap
            // at all: a bullet and the list nested under it are one thought,
            // and spacing them reads as two.
            if separated && offset > 0 { rows.append(MarkdownRow(indent: indent)) }
            emit(block, into: &rows, indent: indent, theme: theme)
        }
    }

    private static func emit(
        _ block: MarkdownBlock,
        into rows: inout [MarkdownRow],
        indent: Int,
        theme: any Theme
    ) {
        switch block {
        case .heading(let level, let content):
            // Level drives weight, not size — there is no size in a cell grid.
            // One and two take the accent; deeper ones step down to emphasis
            // so a document does not end up with six shouting colours.
            let colour = level <= 2 ? theme.accent : theme.foregroundEmphasis
            rows.append(MarkdownRow(
                indent: indent,
                content: spans(content, theme: theme, foreground: colour, bold: true)))

        case .paragraph(let content):
            rows.append(MarkdownRow(
                indent: indent,
                content: spans(content, theme: theme, foreground: theme.foreground)))

        case .codeBlock(let language, let lines):
            let highlighter = SyntaxHighlighting.highlighter(for: language)
            var state = TokenizerState()
            for line in lines {
                let content: [TextSpan]
                if let highlighter {
                    content = highlighted(line, with: highlighter, state: &state, theme: theme)
                } else {
                    content = [TextSpan(line, foreground: theme.foregroundSubtle)]
                }
                rows.append(MarkdownRow(
                    indent: indent + Indent.code,
                    content: content,
                    background: theme.backgroundRaised,
                    wraps: false))
            }

        case .bulletList(let items):
            for item in items {
                emitListItem(item, marker: Gutter.bullet, into: &rows, indent: indent, theme: theme)
            }

        case .orderedList(let start, let items):
            // Markers are padded to a common width so the text column stays
            // aligned when a list runs from 9 to 10.
            let widest = String(start + items.count - 1).count
            for (offset, item) in items.enumerated() {
                let number = String(start + offset)
                let marker = String(repeating: " ", count: widest - number.count) + number + ". "
                emitListItem(item, marker: marker, into: &rows, indent: indent, theme: theme)
            }

        case .blockQuote(let inner):
            var quoted: [MarkdownRow] = []
            emit(inner, into: &quoted, indent: 0, theme: theme, separated: true)
            for var row in quoted {
                // A border edge rather than a glyph, so the rail also covers
                // the rows a long quoted paragraph wraps onto. The rail sits
                // flush against the text for now — a column of breathing room
                // needs leading-only padding, which the framework does not yet
                // have.
                row.indent += indent
                row.rail = theme.separator
                rows.append(row)
            }

        case .thematicBreak:
            rows.append(MarkdownRow(
                indent: indent,
                content: [TextSpan(String(repeating: Gutter.rule, count: ruleWidth),
                                   foreground: theme.separator)],
                wraps: false))
        }
    }

    /// A rule has no container width to measure against at flatten time, so it
    /// is drawn long and clipped by the column it lands in.
    private static let ruleWidth = 200

    private static func emitListItem(
        _ item: MarkdownListItem,
        marker: String,
        into rows: inout [MarkdownRow],
        indent: Int,
        theme: any Theme
    ) {
        var itemRows: [MarkdownRow] = []
        emit(item.blocks, into: &itemRows, indent: 0, theme: theme, separated: false)
        guard !itemRows.isEmpty else { return }

        for (offset, var row) in itemRows.enumerated() {
            row.indent += indent + (offset == 0 ? 0 : marker.count)
            if offset == 0 {
                // Only the first row wears the marker; the rest align under
                // the text because the content column starts past it.
                row.gutter = [TextSpan(marker, foreground: theme.foregroundMuted)] + row.gutter
            }
            rows.append(row)
        }
    }

    // MARK: - Inline styling

    /// Flatten inline nodes into spans, carrying emphasis down through nesting.
    private static func spans(
        _ inlines: [MarkdownInline],
        theme: any Theme,
        foreground: Color,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) -> [TextSpan] {
        inlines.flatMap { inline -> [TextSpan] in
            switch inline {
            case .text(let value):
                return [TextSpan(value, foreground: foreground, bold: bold,
                                 italic: italic, underline: underline)]
            case .strong(let inner):
                return spans(inner, theme: theme, foreground: foreground,
                             bold: true, italic: italic, underline: underline)
            case .emphasis(let inner):
                return spans(inner, theme: theme, foreground: foreground,
                             bold: bold, italic: true, underline: underline)
            case .code(let value):
                // Code keeps its own colour whatever it is nested inside —
                // it is a different kind of thing, not emphasised prose.
                return [TextSpan(value, foreground: theme.secondary,
                                 background: theme.backgroundRaised)]
            case .link(let content, let destination):
                // The destination is dropped rather than appended. A terminal
                // cannot follow it, and printing every URL inline is what
                // makes rendered markdown unreadable in a narrow column.
                let text = content.isEmpty ? [MarkdownInline.text(destination)] : content
                return spans(text, theme: theme, foreground: theme.accent,
                             bold: bold, italic: italic, underline: true)
            }
        }
    }

    private static func highlighted(
        _ line: String,
        with highlighter: any SyntaxHighlighter,
        state: inout TokenizerState,
        theme: any Theme
    ) -> [TextSpan] {
        let syntax = SyntaxTheme.defaultDark
        // Spans carry ranges into the exact line they were tokenised from,
        // so the text is sliced here rather than carried along.
        return highlighter.tokenize(line: line, state: &state).map { span in
            TextSpan(String(line[span.range]),
                     foreground: syntax.color(for: span.token),
                     background: theme.backgroundRaised)
        }
    }
}

/// Which lexer, if any, a fence's info string selects.
enum SyntaxHighlighting {
    static func highlighter(for language: String?) -> (any SyntaxHighlighter)? {
        switch language {
        case "swift": SwiftSyntaxHighlighter()
        default: nil
        }
    }
}
