// Rendering the parsed tree.
//
// The tree is flattened to a flat list of rows before anything is built, for
// two reasons. The obvious one is that a view whose body contains itself is an
// infinitely recursive opaque type, and markdown nests — a list item holds
// blocks, which may hold another list. The better one is that flattening is
// where indentation is decided, and deciding it once means a wrapped line
// lands under the text it continues rather than under the bullet.
//
// Each row becomes `HStack { indent; gutter; content }`. The content sits in
// its own narrower column, so `Text` wraps it inside that column — which is
// what produces a hanging indent without the framework having edge-aware
// padding yet.

/// One rendered line of markdown: what sits in the margin, and what sits in
/// the text column beside it.
struct MarkdownRow {
    /// Columns of blank margin before the gutter.
    var indent: Int = 0
    /// Drawn at the margin: a bullet, an ordinal, a quote bar. Occupies its
    /// own column so the content beside it wraps independently.
    var gutter: [TextSpan] = []
    var content: [TextSpan] = []
    /// Fill painted behind the content column — code blocks only.
    var background: Color?
    /// Drawn as a leading border edge on the content column rather than as a
    /// gutter glyph. The difference matters: a gutter marks only the first
    /// line, while a border spans however many rows the content wraps to —
    /// which is what a quote needs and a bullet does not.
    var rail: Color?
    /// Code keeps its own line breaks; prose reflows to the column width.
    var wraps: Bool = true
}

/// Renders a CommonMark subset, styled from the ambient ``Theme``.
///
/// Colours come from semantic roles rather than literals, so a markdown
/// message restyles with the rest of the app: headings take the accent, code
/// sits on a raised surface, quotes take a separator-coloured rail, links take
/// the accent underlined.
///
/// ```swift
/// MarkdownView("""
///     ## What changed
///     Added a `skippedFrame` flag — see [the diff](https://example.com).
///     """)
/// ```
///
/// Parsing happens once in `init`; only the styling pass runs per body
/// evaluation, because it needs a theme and `init` has no environment.
public struct MarkdownView: TerminalView {
    private let blocks: [MarkdownBlock]

    @TerminalEnvironment(\.theme) private var theme

    /// Parse and prepare `source` for rendering.
    public init(_ source: String) {
        self.blocks = Markdown.parse(source)
    }

    /// Render an already-parsed tree — for callers that inspect or transform
    /// the blocks before display.
    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public var body: some TerminalView {
        let rows = MarkdownFlattener.flatten(blocks, theme: theme)
            .enumerated()
            .map(IdentifiedRow.init)
        return VStack(spacing: 0) {
            ForEach(rows) { identified in
                MarkdownRowView(row: identified.row, fallbackBackground: theme.background)
            }
        }
    }
}

private struct IdentifiedRow: Identifiable {
    let id: Int
    let row: MarkdownRow

    init(_ pair: (offset: Int, element: MarkdownRow)) {
        self.id = pair.offset
        self.row = pair.element
    }
}

/// One row: margin, gutter, then the text column that wraps within itself.
private struct MarkdownRowView: TerminalView {
    let row: MarkdownRow
    let fallbackBackground: Color

    var body: some TerminalView {
        HStack(spacing: 0) {
            if row.indent > 0 {
                Text(String(repeating: " ", count: row.indent))
            }
            if !row.gutter.isEmpty {
                Text(spans: row.gutter)
            }
            content
        }
    }

    @TerminalViewBuilder
    private var content: some TerminalView {
        if let rail = row.rail {
            styledContent.border(.heavy, color: rail, edges: .leading)
        } else {
            styledContent
        }
    }

    private var styledContent: some TerminalView {
        // A blank row still has to occupy one, so an empty span list would
        // measure as no height at all and the gap would vanish.
        Text(spans: row.content.isEmpty ? [TextSpan(" ")] : row.content)
            .wrap(row.wraps ? .wrap : .truncate(.tail))
            .background(row.background ?? fallbackBackground)
    }
}
