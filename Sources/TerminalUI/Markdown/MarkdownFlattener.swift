// Tree → rows.
//
// This is where markdown stops being a document and becomes lines on a grid,
// and where every styling decision is made. Each element's look is its theme
// default with the app's ``MarkdownStyle`` laid over it — no literal colour
// appears here, which is what lets a markdown message restyle with the rest of
// the app, and an app restyle one element without restating the others.

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

    /// What a flatten styles with, resolved from the environment once and
    /// carried down the block tree.
    struct Context {
        let theme: any Theme
        /// Lexers for fenced blocks, by the fence's language.
        let highlighters: SyntaxHighlighters
        /// The app's element styles, laid over the theme defaults.
        let style: MarkdownStyle
    }

    /// The settled look of a run of text: every attribute decided, from the
    /// theme default up through whatever the ``MarkdownStyle`` stated.
    struct RunStyle {
        var foreground: Color
        /// `nil` leaves the row's fill showing through.
        var background: Color? = nil
        var bold = false
        var italic = false
        var underline = false
        var prefix = ""
        var suffix = ""

        /// `element`'s stated fields over this style's.
        func layered(_ element: MarkdownStyle.Element) -> RunStyle {
            var run = self
            if let value = element.foreground { run.foreground = value }
            if let value = element.background { run.background = value }
            if let value = element.bold { run.bold = value }
            if let value = element.italic { run.italic = value }
            if let value = element.underline { run.underline = value }
            if let value = element.prefix { run.prefix = value }
            if let value = element.suffix { run.suffix = value }
            return run
        }

        /// The document layer contributes colour and weight only: its
        /// background fills rows rather than sitting behind each run, and its
        /// prefix and suffix are not drawn.
        func layered(document: MarkdownStyle.Element) -> RunStyle {
            var weightOnly = document
            weightOnly.background = nil
            weightOnly.prefix = nil
            weightOnly.suffix = nil
            return layered(weightOnly)
        }

        /// What text inside this element inherits — its look, but not its
        /// prefix and suffix, which belong to the element once.
        var forChildren: RunStyle {
            var run = self
            run.prefix = ""
            run.suffix = ""
            return run
        }

        func span(_ text: String) -> TextSpan {
            TextSpan(text, foreground: foreground, background: background,
                     bold: bold, italic: italic, underline: underline)
        }

        /// `inner` with this element's prefix before it and suffix after,
        /// drawn in this element's style.
        func wrapping(_ inner: [TextSpan]) -> [TextSpan] {
            (prefix.isEmpty ? [] : [span(prefix)]) + inner + (suffix.isEmpty ? [] : [span(suffix)])
        }
    }

    static func flatten(_ blocks: [MarkdownBlock], context: Context) -> [MarkdownRow] {
        var rows: [MarkdownRow] = []
        emit(blocks, into: &rows, indent: 0, context: context, separated: true)
        return rows
    }

    private static func emit(
        _ blocks: [MarkdownBlock],
        into rows: inout [MarkdownRow],
        indent: Int,
        context: Context,
        separated: Bool
    ) {
        for (offset, block) in blocks.enumerated() {
            // A blank line between siblings, never before the first or after
            // the last — leading and trailing gaps are the container's to
            // decide, not the document's. Inside a list item there is no gap
            // at all: a bullet and the list nested under it are one thought,
            // and spacing them reads as two.
            if separated && offset > 0 { rows.append(MarkdownRow(indent: indent)) }
            emit(block, into: &rows, indent: indent, context: context)
        }
    }

    private static func emit(
        _ block: MarkdownBlock,
        into rows: inout [MarkdownRow],
        indent: Int,
        context: Context
    ) {
        let theme = context.theme
        let style = context.style
        switch block {
        case .heading(let level, let content):
            // Level drives weight, not size — there is no size in a cell grid.
            // One and two take the accent; deeper ones step down to emphasis
            // so a document does not end up with six shouting colours.
            let heading = RunStyle(foreground: level <= 2 ? theme.accent : theme.foregroundEmphasis, bold: true)
                .layered(document: style.text)
                .layered(style.heading)
                .layered(style.heading(level: level))
            rows.append(MarkdownRow(
                indent: indent,
                content: heading.wrapping(spans(content, run: heading.forChildren, context: context))))

        case .paragraph(let content):
            let paragraph = RunStyle(foreground: theme.foreground)
                .layered(document: style.text)
                .layered(style.paragraph)
            rows.append(MarkdownRow(
                indent: indent,
                content: paragraph.wrapping(spans(content, run: paragraph.forChildren, context: context))))

        case .codeBlock(let language, let lines):
            // A fence whose language has no lexer still reads as code: the
            // raised fill and a quieter foreground, without token colours.
            let block = RunStyle(foreground: theme.foregroundSubtle, background: theme.backgroundRaised)
                .layered(document: style.text)
                .layered(style.codeBlock)
            let highlighted = context.highlighters[language]?.highlight(lines: lines, theme: theme.syntax)
            for (index, line) in lines.enumerated() {
                let content = highlighted?[index] ?? [TextSpan(line, foreground: block.foreground)]
                rows.append(MarkdownRow(
                    indent: indent + Indent.code,
                    content: content,
                    background: block.background,
                    wraps: false))
            }

        case .bulletList(let items):
            for item in items {
                emitListItem(item, marker: Gutter.bullet, into: &rows, indent: indent, context: context)
            }

        case .orderedList(let start, let items):
            // Markers are padded to a common width so the text column stays
            // aligned when a list runs from 9 to 10.
            let widest = String(start + items.count - 1).count
            for (offset, item) in items.enumerated() {
                let number = String(start + offset)
                let marker = String(repeating: " ", count: widest - number.count) + number + ". "
                emitListItem(item, marker: marker, into: &rows, indent: indent, context: context)
            }

        case .blockQuote(let inner):
            var quoted: [MarkdownRow] = []
            emit(inner, into: &quoted, indent: 0, context: context, separated: true)
            for var row in quoted {
                // A border edge rather than a glyph, so the rail also covers
                // the rows a long quoted paragraph wraps onto. The row view
                // keeps a column of room between the rail and the text.
                row.indent += indent
                row.rail = style.blockQuote.foreground ?? theme.separator
                rows.append(row)
            }

        case .thematicBreak:
            let rule = RunStyle(foreground: theme.separator).layered(style.rule)
            rows.append(MarkdownRow(
                indent: indent,
                content: [rule.span(String(repeating: Gutter.rule, count: ruleWidth))],
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
        context: Context
    ) {
        let markerStyle = RunStyle(foreground: context.theme.foregroundMuted)
            .layered(document: context.style.text)
            .layered(context.style.listMarker)
        var itemRows: [MarkdownRow] = []
        emit(item.blocks, into: &itemRows, indent: 0, context: context, separated: false)
        guard !itemRows.isEmpty else { return }

        for (offset, var row) in itemRows.enumerated() {
            row.indent += indent + (offset == 0 ? 0 : marker.count)
            if offset == 0 {
                // Only the first row wears the marker; the rest align under
                // the text because the content column starts past it.
                row.gutter = [markerStyle.span(marker)] + row.gutter
            }
            rows.append(row)
        }
    }

    // MARK: - Inline styling

    /// Flatten inline nodes into spans, carrying the enclosing run's look down
    /// through nesting and laying each inline element's style over it.
    private static func spans(_ inlines: [MarkdownInline], run: RunStyle, context: Context) -> [TextSpan] {
        let theme = context.theme
        let style = context.style
        return inlines.flatMap { inline -> [TextSpan] in
            switch inline {
            case .text(let value):
                return [run.span(value)]
            case .strong(let inner):
                var strong = run
                strong.bold = true
                strong = strong.layered(style.strong)
                return strong.wrapping(spans(inner, run: strong.forChildren, context: context))
            case .emphasis(let inner):
                var emphasis = run
                emphasis.italic = true
                emphasis = emphasis.layered(style.emphasis)
                return emphasis.wrapping(spans(inner, run: emphasis.forChildren, context: context))
            case .code(let value):
                // Code keeps its own look whatever it is nested inside — it is
                // a different kind of thing, not emphasised prose. Its prefix
                // and suffix share its span, so a padded chip is one run.
                let code = RunStyle(foreground: theme.secondary, background: theme.backgroundRaised)
                    .layered(style.inlineCode)
                return [code.span(code.prefix + value + code.suffix)]
            case .link(let content, let destination):
                // The destination is dropped rather than appended. A terminal
                // cannot follow it, and printing every URL inline is what
                // makes rendered markdown unreadable in a narrow column.
                let text = content.isEmpty ? [MarkdownInline.text(destination)] : content
                var link = run
                link.foreground = theme.accent
                link.underline = true
                link = link.layered(style.link)
                return link.wrapping(spans(text, run: link.forChildren, context: context))
            }
        }
    }
}
