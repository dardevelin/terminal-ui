/// Source code, highlighted, and numbered when asked.
///
/// `language` is looked up in the environment's ``SyntaxHighlighters`` — Swift
/// is there as standard, and `.syntaxHighlighter(_:for:)` adds more — and the
/// tokens take their colours from the app ``Theme``'s ``Theme/syntax``. A
/// language with no lexer is still drawn, in the theme's plain code colour.
///
/// With `lineNumbers`, a muted gutter counts from `firstLineNumber`, so an
/// excerpt keeps the numbering of the file it came from. Long lines follow
/// `.wrap(_:)` like any ``Text``: they wrap by default, and
/// `.wrap(.truncate(.tail))` cuts each one with an ellipsis. Each line is laid
/// out beside its own number, so a wrapped line continues under its code
/// rather than under the gutter.
///
/// A code view is content, not a control: it takes no focus. Put it in a
/// ``ScrollView`` to scroll it.
///
/// ```swift
/// CodeView(excerpt, language: "swift", lineNumbers: true, firstLineNumber: 305)
///     .wrap(.truncate(.tail))
/// ```
public struct CodeView: TerminalView {
    private let lines: [String]
    private let language: String?
    private let lineNumbers: Bool
    private let firstLineNumber: Int
    private let syntaxOverride: SyntaxTheme?

    @TerminalEnvironment(\.theme) private var theme
    @TerminalEnvironment(\.syntaxHighlighters) private var highlighters

    /// Columns between the gutter's numbers and the code.
    private static let gutterGap = "  "

    /// Creates a view over `code`.
    ///
    /// - Parameters:
    ///   - code: The source. One trailing newline ends the last line rather
    ///     than starting an empty one.
    ///   - language: Looked up in the environment's lexers; `nil` or an
    ///     unregistered name draws the code unhighlighted.
    ///   - lineNumbers: Whether to draw the numbered gutter.
    ///   - firstLineNumber: The number the first line carries.
    ///   - theme: Token colours for this view alone; `nil` follows the app
    ///     ``Theme``'s ``Theme/syntax``.
    public init(_ code: String, language: String? = nil, lineNumbers: Bool = false,
                firstLineNumber: Int = 1, theme: SyntaxTheme? = nil) {
        var lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        self.lines = lines
        self.language = language
        self.lineNumbers = lineNumbers
        self.firstLineNumber = firstLineNumber
        self.syntaxOverride = theme
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let syntax = syntaxOverride ?? theme.syntax
        let runs = highlighters[language]?.highlight(lines: lines, theme: syntax)
            ?? lines.map { [TextSpan($0, foreground: syntax.plain)] }
        let lastNumber = firstLineNumber + max(0, lines.count - 1)
        let gutterWidth = max(String(firstLineNumber).count, String(lastNumber).count)
        let rows = runs.enumerated().map { index, spans in
            CodeRow(id: index, number: firstLineNumber + index, spans: spans)
        }
        let gutterColor = theme.foregroundMuted

        return VStack(spacing: 0) {
            ForEach(rows) { row in
                if lineNumbers {
                    HStack(spacing: 0) {
                        Text(row.paddedNumber(width: gutterWidth) + Self.gutterGap)
                            .foreground(gutterColor)
                        row.code
                    }
                } else {
                    row.code
                }
            }
        }
    }
}

private struct CodeRow: Identifiable {
    let id: Int
    let number: Int
    let spans: [TextSpan]

    /// A blank line still occupies its row. Spans with no text in them —
    /// none at all, or only empty ones — would measure as no height and the
    /// gap would close up.
    var code: Text {
        Text(spans: spans.contains { !$0.text.isEmpty } ? spans : [TextSpan(" ")])
    }

    func paddedNumber(width: Int) -> String {
        let digits = String(number)
        return String(repeating: " ", count: max(0, width - digits.count)) + digits
    }
}
