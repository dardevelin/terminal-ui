/// A row's label, as a `Form` needs to see it.
///
/// A control states its label width here so `Form` can compute a column
/// without knowing what the control is. Conforming is the entire cost of
/// participating — no control is forked into a form-aware variant, and a
/// control rendered outside a `Form` never sees a resolved width and behaves
/// exactly as it did before.
protocol _FormRowLabel {
    var formLabelText: String { get }
}

/// Label text padded to the shared column, or unpadded outside a `Form`.
///
/// Shared by every participating control so the padding rule is stated once —
/// a control that padded differently would break the column it was meant to
/// join.
struct FormLabel: TerminalView {
    let text: String

    @TerminalEnvironment(\.formLabelWidth) private var width
    @TerminalEnvironment(\.formStacksRows) private var stacks

    var body: some TerminalView {
        Text(Self.rendered(text: text, width: width, stacks: stacks))
    }

    /// The label exactly as it is drawn.
    ///
    /// Stated as one function because a control that needs to know where its
    /// own content begins — `Slider`, translating a click into a position —
    /// must measure the *rendered* label, not the raw string. Re-deriving that
    /// from `text.count` was wrong inside a `Form`, where the label is padded
    /// to the shared column.
    static func rendered(text: String, width: Int?, stacks: Bool) -> String {
        // An unlabelled row contributes nothing to the column and must not
        // emit a stray separator space of its own.
        guard !text.isEmpty else { return "" }
        guard let width, !stacks else { return "\(text) " }
        return "\(text) " + String(repeating: " ", count: max(0, width - text.count))
    }
}

/// A container that lays out labelled controls with a shared label column.
///
/// ```swift
/// Form {
///     Section("Appearance") {
///         Toggle("Dark mode", isOn: $dark)
///         Picker("Theme", selection: $theme) { ... }
///     }
/// }
/// ```
///
/// The alignment is the feature: every row's control begins at the same
/// column, computed from the widest label in the whole form, so the eye can
/// scan down the controls. A `Form` that did not align would be a `VStack`.
///
/// Rows are the framework's labelled controls — ``Toggle``, ``Picker``,
/// ``Slider``, ``Stepper``, ``Gauge``, ``LabeledContent`` — grouped by
/// ``Section``. The whole form scrolls vertically as one unit, and focus
/// treats it as one list: Tab moves between operable controls, the arrow
/// row-cursor walks every row (including read-only ones) and crosses
/// section boundaries rather than stopping at them. Reach for a plain
/// `VStack` when the content is not label + control rows — the shared
/// column is the only thing a `Form` adds.
///
/// Rows stack their label above the control when the terminal is too narrow to
/// place both side by side. The threshold is derived from the measured label
/// column and a minimum control budget rather than a magic width.
public struct Form<Content: TerminalView>: TerminalView {
    let content: Content

    /// Measured once, at construction.
    ///
    /// `content` is immutable, so the column is a function of data fixed by
    /// `init` — while `body` re-evaluates on every dirty frame. Measuring there
    /// walked the whole subtree *and evaluated every control's body* to find
    /// the labels, which cost 93% of `Form.body` and made the form 2.16× a
    /// flat `VStack`. It also fired each control's debug warnings twice per
    /// frame. `Picker` paid for this same mistake one commit earlier.
    private let labelColumn: Int

    @TerminalEnvironment(\.terminalSize) private var terminalSize

    public init(@TerminalViewBuilder content: () -> Content) {
        let content = content()
        self.content = content
        self.labelColumn = (FormLabels.collect(from: content).map(\.count).max() ?? 0) + 1
    }

    /// Narrowest control worth rendering beside a label. Below this the row
    /// stacks instead — a two-cell control column is unreadable, and silently
    /// clipping it would hide state the user is trying to read.
    private static var minimumControlWidth: Int { 12 }

    public var body: some TerminalView {
        let column = labelColumn
        let stacks = terminalSize.cols < column + Self.minimumControlWidth

        // A settings screen scrolls. Unconditionally, not on overflow: the
        // shipped `ScrollView` already suppresses its scrollbar and its ▲/▼
        // glyphs when the content fits, so gating the composition on a
        // measured overflow would answer the same question twice — and would
        // have to answer it during `body`, where the viewport height is not
        // yet known. Clipping instead would leave the rows below the fold
        // focusable but invisible.
        return ScrollView(.vertical) {
            _FormBody(content: content)
                .environment(\.formLabelWidth, column)
                .environment(\.formStacksRows, stacks)
                // A form is one list and its sections are grouping, not walls.
                // A stack holds arrows at its last child by default, which is
                // right beside unrelated content and wrong here: the next
                // section's rows are where this list continues.
                .environment(\.focusBoundaryPolicy, .escapeToParent)
        }
    }
}

/// Lays out a form's children, numbering the sections among them.
///
/// A section cannot tell on its own whether it is the first — siblings all see
/// the same environment — so the ordinal is stamped here, where the sequence
/// is visible, and read back by `_SectionSeparator`.
struct _FormBody<Content: TerminalView>: TerminalView {
    let content: Content

    var body: Never { fatalError() }

    /// The form's children with each section's ordinal stamped on it.
    ///
    /// A form whose content is a single row rather than a builder tuple has no
    /// children to number, so it passes through unchanged.
    var numberedChildren: [Any] {
        let children = ViewTree.children(of: content)
        guard !children.isEmpty else { return [content] }

        // Only the *first* rendered section suppresses its rule, so what a
        // section needs is "does anything precede me", not an ordinal. A
        // boolean also survives nesting: a `ForEach` of sections inherits
        // `true` from its position and every section inside draws its rule,
        // which is right — they all have something above them.
        var seenSection = false
        return children.map { child in
            // A child may *contain* sections rather than be one (a `ForEach`
            // of sections, or one behind an `if`). Testing only for a direct
            // `Section` left those unstamped, so each believed itself first
            // and the rules silently vanished. An empty section renders
            // nothing and must not count as something preceding.
            guard FormContent.containsVisibleSection(child),
                  let view = child as? any TerminalView else { return child }
            let stamped = stampSectionPrecedence(view, seenSection)
            seenSection = true
            return stamped
        }
    }

    /// Opens the existential so `.environment` — a generic member — can be
    /// called on a child whose concrete type the form does not know.
    private func stampSectionPrecedence(_ view: some TerminalView, _ precededBy: Bool) -> Any {
        view.environment(\.formSectionIsPreceded, precededBy)
    }
}

extension _FormBody: _GraphVStack {
    func graphChildren() -> [Any] { numberedChildren }
}

/// Recovers the label of every row in a form's content.
///
/// Uses the same traversal as `PickerOptions`: mirror the graph's own dispatch
/// and end by evaluating `body`, so a row nested in a `Section`, produced by a
/// `ForEach`, or wrapped in a modifier is still found. Naming container types
/// by hand would silently drop rows from the column measurement, leaving them
/// misaligned rather than visibly broken.
enum FormLabels {
    static func collect(from content: Any) -> [String] {
        var labels: [String] = []
        walk(content, into: &labels)
        return labels
    }

    private static func walk(_ value: Any, into labels: inout [String]) {
        if let row = value as? any _FormRowLabel {
            labels.append(row.formLabelText)
            // A row's own subtree cannot contain another row, and descending
            // into it would evaluate control bodies for no reason.
            return
        }
        for child in ViewTree.children(of: value) {
            walk(child, into: &labels)
        }
    }
}

/// A titled group of rows within a `Form`.
///
/// Renders an uppercase header, its rows, an optional footer, and a `Divider`
/// separating it from the next section — the shipped `Divider`, not a second
/// kind of rule. Grouping is visual only: focus walks straight through a
/// section boundary, because a form is one list.
///
/// ```swift
/// Form {
///     Section("Privacy") {
///         Toggle("Telemetry", isOn: $telemetry)
///         Toggle("Crash reports", isOn: $crashReports)
///     }
///     Section("About") {
///         LabeledContent("Version", value: "1.0.0")
///     }
/// }
/// ```
///
/// An empty section renders **nothing**: an orphan header over no rows, or a
/// divider with nothing after it, reads as a rendering fault rather than as an
/// empty state.
public struct Section<Header: TerminalView, Content: TerminalView, Footer: TerminalView>: TerminalView {
    let header: Header
    let content: Content
    let footer: Footer

    /// Whether this section has anything to show, decided once at
    /// construction. `body` re-evaluates every dirty frame, and answering this
    /// there re-walked the subtree — evaluating every control's body — for a
    /// result fixed by `init`. See `Form.labelColumn` for the same fix.
    ///
    /// A section holding only `EmptyView` must render nothing: not its header,
    /// not its rule. Checked by looking for any renderable leaf rather than
    /// only for labelled rows, so a section of plain `Text` still counts.
    let isEmpty: Bool

    /// - Parameters:
    ///   - content: The section's rows.
    ///   - header: Rendered uppercase and dim above the rows.
    ///   - footer: Rendered after the rows; `EmptyView()` for none.
    public init(
        @TerminalViewBuilder content: () -> Content,
        @TerminalViewBuilder header: () -> Header,
        @TerminalViewBuilder footer: () -> Footer
    ) {
        let content = content()
        self.content = content
        self.header = header()
        self.footer = footer()
        self.isEmpty = !FormContent.hasRenderableLeaf(content)
    }

    public var body: some TerminalView {
        VStack {
            if !isEmpty {
                // The separator sits *above* the section, drawn only when
                // something precedes it. Owning it on the upper side is what
                // keeps a rule from trailing the final section; the
                // alternative needs the parent to know which child is last,
                // which a result builder does not expose. `Form` clears the
                // flag for the content that opens the form.
                _SectionSeparator()
                _SectionHeader(header: header)
                content
                footer
            }
        }
    }

}

extension Section: _FormSection {
    var isEmptySection: Bool { isEmpty }
}

extension Section where Header == Text, Footer == EmptyView {
    /// A section with a plain title and no footer — the common case.
    public init(_ title: String, @TerminalViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

/// The rule between two sections.
///
/// Draws only when a section already precedes it in this form. The decision
/// cannot be made from the environment alone — sibling sections all read the
/// same values — so the enclosing `Form` hands each section its ordinal, and
/// the first one suppresses its rule.
struct _SectionSeparator: TerminalView {
    @TerminalEnvironment(\.formSectionIsPreceded) private var isPreceded

    var body: some TerminalView {
        if isPreceded { Divider() } else { EmptyView() }
    }
}

/// Renders a section header in the established convention: uppercase and dim,
/// so it reads as a grouping label rather than as content.
struct _SectionHeader<Header: TerminalView>: TerminalView {
    let header: Header

    var body: some TerminalView {
        _UppercasedText(source: header).foreground(.gray)
    }
}

/// Uppercases the text of a header subtree without requiring the caller to
/// shout at the call site — `Section("Appearance")` reads better than
/// `Section("APPEARANCE")`, and the casing is presentation.
struct _UppercasedText<Source: TerminalView>: TerminalView {
    let source: Source

    var body: some TerminalView {
        let text = ViewTree.firstText(in: source)
        return Text(text.uppercased())
    }
}

/// Marks `Section` so `Form` can recognise one without knowing its three
/// generic parameters.
protocol _FormSection {
    /// Whether this section renders nothing, so callers can skip it without
    /// knowing its three generic parameters.
    var isEmptySection: Bool { get }
}

enum FormContent {
    /// Whether `value` is, or contains, a section that will actually render.
    ///
    /// An empty section draws nothing, so it must not count as "something
    /// precedes you" — otherwise the section after it opens the form with a
    /// rule that has nothing above it.
    static func containsVisibleSection(_ value: Any) -> Bool {
        if let section = value as? any _FormSection { return !section.isEmptySection }
        return ViewTree.children(of: value).contains { containsVisibleSection($0) }
    }

    /// Whether anything beneath `value` would draw.
    ///
    /// `EmptyView` is the only leaf that renders nothing, so a subtree made
    /// solely of them — however deeply nested by builders and conditionals —
    /// is empty. Anything else (a `Text`, a control, a `Divider`) counts.
    static func hasRenderableLeaf(_ value: Any) -> Bool {
        if value is EmptyView { return false }
        let children = ViewTree.children(of: value)
        // A leaf that is not EmptyView draws something.
        if children.isEmpty { return true }
        return children.contains { hasRenderableLeaf($0) }
    }
}

/// A row pairing a label with arbitrary content.
///
/// ```swift
/// LabeledContent("Version", value: "1.0.0")
/// ```
///
/// The read-only counterpart to the interactive controls: it participates in
/// the same shared column so a form mixing values and controls still aligns.
/// Like ``Gauge``, the arrow row-cursor visits it but Tab skips it — there
/// is nothing to operate, yet stopping the walk above it would strand the
/// rows below. Reach for a bare `Text` only outside a form, where no column
/// exists to join.
public struct LabeledContent<Label: TerminalView, Content: TerminalView>: TerminalView {
    let label: Label
    let content: Content

    public init(
        @TerminalViewBuilder content: () -> Content,
        @TerminalViewBuilder label: () -> Label
    ) {
        self.content = content()
        self.label = label()
    }

    public var body: some TerminalView {
        FormRow(label: formLabelText) { content }
            // A row the arrow cursor visits and Tab skips: there is nothing
            // here to operate, but stopping the walk above it would strand
            // every row below in a list the user can see more of.
            .focusable()
            .environment(\.focusIsReadOnly, true)
    }
}

extension LabeledContent where Label == Text, Content == Text {
    /// The common case: a label and a value, both plain strings.
    public init(_ label: String, value: String) {
        self.init(content: { Text(value) }, label: { Text(label) })
    }
}

extension LabeledContent: _FormRowLabel {
    var formLabelText: String { ViewTree.firstText(in: label) }
}

/// The layout shared by every form row: label then control, or label above
/// control when the terminal is too narrow.
///
/// Controls compose this rather than each deciding how to place their own
/// label, which is what keeps the column consistent when a form mixes types.
struct FormRow<Content: TerminalView>: TerminalView {
    let label: String
    let content: Content

    @TerminalEnvironment(\.formStacksRows) private var stacks

    init(label: String, @TerminalViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some TerminalView {
        if stacks {
            VStack {
                FormLabel(text: label)
                content
            }
        } else {
            HStack {
                FormLabel(text: label)
                content
            }
        }
    }
}
