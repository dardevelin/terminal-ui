/// How a ``MarkdownView`` draws each kind of element.
///
/// Every field starts unset, and an unset field keeps the default — drawn from
/// the ambient ``Theme``, so an unstyled view looks exactly as it always has. A
/// style therefore states only what it changes:
///
/// ```swift
/// var style = MarkdownStyle()
/// style.heading.foreground = theme.info
/// style.h2.prefix = "## "                       // keep the marker
/// style.inlineCode = .init(foreground: theme.destructive,
///                          background: theme.backgroundOverlay,
///                          prefix: " ", suffix: " ")   // a padded chip
///
/// MarkdownView(reply).markdownStyle(style)
/// ```
///
/// Styles nest per subtree like every other environment value, so one screen
/// can draw a reply in one style and the model's thinking in a quieter one.
///
/// ## Precedence
///
/// For any piece of text the most specific statement wins: a heading level
/// (``h2``) over all headings (``heading``) over the whole document (``text``)
/// over the theme's default. Emphasis, strong text and links are layered on
/// top of the text they sit in, so a bold word in a heading keeps the
/// heading's colour unless ``strong`` says otherwise. Inline code keeps its
/// own colours wherever it appears — it is a different kind of thing, not
/// emphasised prose — so only ``inlineCode`` restyles it.
///
/// ## Background
///
/// On a run of text — a heading, a paragraph, inline code, a link — a
/// background is drawn behind that text only, which with a padding prefix and
/// suffix makes a chip. On ``text`` it fills the whole document, row by row,
/// blank rows included: the shape of a block set apart, such as a model's
/// thinking. On ``codeBlock`` it fills the block.
public struct MarkdownStyle: Sendable, Equatable {

    /// The look of one kind of element. Every field is optional; `nil` defers
    /// to whatever the element would otherwise be drawn with.
    public struct Element: Sendable, Equatable {
        /// Text colour. For ``MarkdownStyle/blockQuote`` this colours the rail.
        public var foreground: Color?
        /// See ``MarkdownStyle``'s Background section for what this fills.
        public var background: Color?
        /// Bold weight. `false` turns off bold the element would otherwise
        /// have — a ``MarkdownStyle/strong`` that stands out by colour alone.
        public var bold: Bool?
        /// Italic, where the terminal draws it. `false` turns it off, as on
        /// ``MarkdownStyle/emphasis`` shown by colour instead.
        public var italic: Bool?
        /// Underline. `false` turns it off — on ``MarkdownStyle/link``, say,
        /// where the theme default underlines.
        public var underline: Bool?
        /// Drawn before the element's text, in the element's style — a
        /// heading marker such as `"## "`, or padding that widens a chip.
        /// Honoured by text runs: headings, paragraphs, strong, emphasis,
        /// links and inline code.
        public var prefix: String?
        /// Drawn after the element's text, in the element's style. Honoured
        /// where ``prefix`` is.
        public var suffix: String?

        /// Creates an element style; every argument defaults to unset.
        public init(foreground: Color? = nil, background: Color? = nil,
                    bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil,
                    prefix: String? = nil, suffix: String? = nil) {
            self.foreground = foreground
            self.background = background
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.prefix = prefix
            self.suffix = suffix
        }
    }

    /// The whole document: the base every text element builds on. Its
    /// background fills the document; its prefix and suffix are not drawn.
    public var text = Element()
    /// Paragraph text.
    public var paragraph = Element()
    /// Every heading level. Default: bold, the accent for levels one and two,
    /// emphasis below.
    public var heading = Element()
    /// `#` headings, over ``heading``.
    public var h1 = Element()
    /// `##` headings, over ``heading``.
    public var h2 = Element()
    /// `###` headings, over ``heading``.
    public var h3 = Element()
    /// `####` headings, over ``heading``.
    public var h4 = Element()
    /// `#####` headings, over ``heading``.
    public var h5 = Element()
    /// `######` headings, over ``heading``.
    public var h6 = Element()
    /// `**strong**` text, layered over the text around it. Default: bold.
    public var strong = Element()
    /// `*emphasised*` text, layered over the text around it. Default: italic.
    public var emphasis = Element()
    /// Code inline in a sentence, between single backticks. Default: the
    /// secondary colour on a raised fill.
    public var inlineCode = Element()
    /// Link text, layered over the text around it; the destination is not
    /// drawn. Default: the accent, underlined.
    public var link = Element()
    /// Fenced code. The foreground colours code no lexer highlights —
    /// highlighted code takes ``Theme/syntax`` — and the background fills the
    /// block. Default: a quieter foreground on a raised fill.
    public var codeBlock = Element()
    /// List bullets and ordinals. Default: muted.
    public var listMarker = Element()
    /// Block quotes: the foreground colours the rail down the quote's side.
    /// Default: the separator.
    public var blockQuote = Element()
    /// Thematic breaks. Default: the separator.
    public var rule = Element()

    /// A style that changes nothing: every element is drawn by default.
    public init() {}

    /// The level-specific style for a heading of `level`, or an empty style
    /// for a level outside one to six.
    func heading(level: Int) -> Element {
        switch level {
        case 1: h1
        case 2: h2
        case 3: h3
        case 4: h4
        case 5: h5
        case 6: h6
        default: Element()
        }
    }
}

extension TerminalView {
    /// Draw enclosed ``MarkdownView``s with `style`. See ``MarkdownStyle``.
    public func markdownStyle(_ style: MarkdownStyle)
        -> ModifiedView<Self, EnvironmentModifier<MarkdownStyle>> {
        environment(\.markdownStyle, style)
    }
}
