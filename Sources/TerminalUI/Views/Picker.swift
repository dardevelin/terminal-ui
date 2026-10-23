/// Glyphs shared by every picker style, named once so the styles cannot drift
/// apart and tests can assert against the same source the renderer uses.
public enum PickerGlyph {
    /// Marks the committed value. Distinct from the focus cursor: the cursor
    /// says "where you are", this says "what is chosen", and while a list is
    /// open those are frequently different rows.
    public static let selected = "•"
    /// Highlight cursor, matching the framework's established `▸` convention.
    public static let cursor = "▸"
    /// Collapsed-dropdown affordance.
    public static let collapsed = "▾"
    /// Stands in for the option list when a picker has none. A picker with an
    /// empty label region would read as a rendering fault.
    public static let emptyPlaceholder = "—"
}

/// How a `Picker` presents its options.
///
/// Set through the environment rather than an initialiser argument so a whole
/// settings screen can state the choice once, matching how the framework
/// already scopes other presentation decisions.
public enum PickerStyle: Sendable, Equatable {
    /// Every option listed; the cursor moves and Enter commits.
    case inline
    /// One horizontal row; Left/Right move *and* commit, with no separate
    /// confirm step — the platform convention for segmented controls.
    case segmented
    /// Collapsed to the current value; opens a list on Enter/Space/Down.
    case dropdown
}

extension TerminalView {
    /// Choose how `Picker`s in this subtree present their options.
    public func pickerStyle(_ style: PickerStyle)
        -> ModifiedView<Self, EnvironmentModifier<PickerStyle>> {
        environment(\.pickerStyle, style)
    }
}

/// A control for selecting one value from a set of mutually exclusive options.
///
/// Options are ordinary view-builder content tagged with `.tag(_:)`, exactly as
/// in SwiftUI — which means `ForEach` and `if`/`else` compose without a
/// picker-specific builder:
///
/// ```swift
/// Picker("Theme", selection: $theme) {
///     ForEach(Theme.allCases) { Text($0.title).tag($0) }
/// }
/// .pickerStyle(.dropdown)
/// ```
///
/// The whole control is one stop in the Tab order regardless of style, and
/// the keys inside it follow ``PickerStyle``: `.inline` lists every option
/// (Up/Down move the `▸` cursor, Enter/Space commit the `•` selection),
/// `.segmented` is one row where Left/Right move *and* commit, `.dropdown`
/// collapses to the current value and opens on Enter/Space/Down — Enter
/// commits and closes, Esc closes without committing. Reach for ``Toggle``
/// when the choice is binary, or a `List` when the rows are data to browse
/// rather than a setting to hold.
///
/// The selection lives entirely in the binding. Nothing about which option is
/// chosen is stored in the render graph, so reordering or filtering the option
/// list cannot desynchronise it.
///
/// Wired to an `@Observable` model, the way the Settings example does it:
/// ```swift
/// Picker("Theme", selection: Binding(
///     get: { model.theme }, set: { model.theme = $0 }
/// )) {
///     ForEach(Theme.allCases) { theme in
///         Text(theme.title).tag(theme)
///     }
/// }
/// .pickerStyle(.segmented)
/// ```
public struct Picker<SelectionValue: Hashable, Content: TerminalView>: TerminalView {
    /// Label rendered before the options — or in the shared label column
    /// inside a ``Form``.
    public let label: String
    /// The committed choice. Written only when the user commits, never
    /// while the highlight is merely browsing.
    public let selection: Binding<SelectionValue>
    /// The option views, each carrying a `.tag(_:)` whose type matches
    /// `SelectionValue`.
    public let content: Content

    /// Cursor position while the user is browsing. Separate from `selection`
    /// because inline and dropdown let the highlight move without committing;
    /// `-1` means "not yet placed", so the first render can seed it from the
    /// current selection rather than snapping the user to row 0.
    @TerminalState private var highlight: Int = -1
    @TerminalState private var isOpen: Bool = false

    @TerminalEnvironment(\.pickerStyle) private var style
    @TerminalEnvironment(\.isEnabled) private var isEnabled

    /// Collected once, at construction.
    ///
    /// `content` is immutable, so the option list is a function of data fixed
    /// by `init` — while `body` re-evaluates on every dirty frame. Walking the
    /// content tree there cost ~3x a hand-written equivalent and allocated a
    /// `Set`, the result array, and one `[Any]` box per container visited, on
    /// the framework's hottest path.
    private let options: [PickerOption<SelectionValue>]

    /// Creates a picker; the option list is collected from `content`'s
    /// `.tag(_:)` values once, here, not per frame.
    ///
    /// - Parameters:
    ///   - label: Text rendered before the options.
    ///   - selection: Binding the committed choice is written through.
    ///   - content: Option views, each tagged with `.tag(_:)`.
    public init(
        _ label: String,
        selection: Binding<SelectionValue>,
        @TerminalViewBuilder content: () -> Content
    ) {
        self.label = label
        self.selection = selection
        let content = content()
        self.content = content
        self.options = PickerOptions.collect(from: content, as: SelectionValue.self)
    }

    @TerminalEnvironment(\.theme) private var theme

    public var body: some TerminalView {
        let options = self.options
        let selected = options.firstIndex { $0.value == selection.get() }
        // Bindings must be projected here, in `body` — projecting inside a
        // handler closure yields a binding with no node to write through.
        let highlightBinding = $highlight
        let openBinding = $isOpen
        let selectionBinding = selection

        let cursor = PickerCursor(
            highlight: highlightBinding,
            selectedIndex: selected,
            count: options.count
        )

        return PickerBody(
            label: label,
            titles: options.map(\.title),
            selected: selected,
            rawSelection: "\(selection.get())",
            style: style,
            isEnabled: isEnabled,
            isOpen: openBinding.get(),
            cursor: cursor,
            commit: { index in
                guard options.indices.contains(index) else { return }
                selectionBinding.set(options[index].value)
            },
            setOpen: { shouldOpen in
                // Opening seeds the cursor on the committed value so the list
                // appears with the current choice under the cursor rather than
                // at the top. An empty picker never opens: an overlay with no
                // rows cannot be dismissed by choosing anything.
                if shouldOpen {
                    guard !options.isEmpty else { return }
                    cursor.place(at: selected ?? 0)
                }
                openBinding.set(shouldOpen)
            }
        )
    }
}

extension Picker: _FormRowLabel {
    var formLabelText: String { label }
}

/// Cursor arithmetic, kept out of the view so movement rules are stated once
/// and shared by all three styles rather than re-derived per style.
struct PickerCursor {
    let highlight: Binding<Int>
    let selectedIndex: Int?
    let count: Int

    /// Where the cursor sits, seeded from the committed value the first time.
    /// A picker opened on its third option must not jump the user to the first.
    var index: Int {
        let raw = highlight.get()
        guard raw >= 0 else { return selectedIndex ?? 0 }
        return max(0, min(count - 1, raw))
    }

    /// Move by `delta`, clamping at the ends.
    ///
    /// Clamping rather than wrapping: in a vertical list wrapping fights the
    /// framework's boundary-feedback convention, and in a segmented row it
    /// would silently commit the opposite end of the control on an overshoot.
    /// Returns the new index, or nil when already at the boundary — the
    /// segmented style commits that index, and every style reports an
    /// unmoved cursor as `.ignored` so the parent can give boundary feedback.
    func move(by delta: Int) -> Int? {
        guard count > 0 else { return nil }
        let next = max(0, min(count - 1, index + delta))
        guard next != index else { return nil }
        highlight.set(next)
        return next
    }

    func place(at index: Int) {
        highlight.set(max(0, min(count - 1, index)))
    }
}

/// The rendered picker.
///
/// Split from `Picker` so rendering depends only on already-resolved values —
/// titles, indices, callbacks — never on reading a binding mid-layout. Option
/// *values* are not needed here at all, so this takes titles rather than
/// `PickerOption`s and stays free of the selection generic.
struct PickerBody: TerminalView {
    @TerminalEnvironment(\.theme) private var theme
    let label: String
    let titles: [String]
    let selected: Int?
    /// Shown when the bound value matches no option. Rendered raw rather than
    /// coerced to a valid option, so a consumer bug stays visible.
    let rawSelection: String
    let style: PickerStyle
    let isEnabled: Bool
    let isOpen: Bool
    let cursor: PickerCursor
    let commit: (Int) -> Void
    let setOpen: (Bool) -> Void

    @TerminalEnvironment(\.terminalSize) private var terminalSize

    private var isEmpty: Bool { titles.isEmpty }

    private var terminalWidth: Int { terminalSize.cols }

    /// Label plus placeholder, used by every style when there is nothing to
    /// choose from. Rendering the bare label instead would look like a
    /// half-drawn control.
    private var emptyBody: some TerminalView {
        HStack {
            FormLabel(text: label)
            _EmptyPlaceholder(PickerGlyph.emptyPlaceholder)
        }
    }

    var body: some TerminalView {
        VStack {
            if isEmpty {
                emptyBody
            } else {
                switch style {
                case .inline: inlineBody
                case .segmented: segmentedBody
                case .dropdown: dropdownBody
                }
            }
        }
        .foreground(isEnabled ? theme.foreground : theme.foregroundMuted)
    }

    // MARK: - Shared row rendering and movement

    /// The option list, one row each.
    ///
    /// `showsSelectionMarker` is the only difference between the inline and
    /// dropdown lists: inline draws the cursor *and* the committed value,
    /// because it browses and commits in the same view, while an open dropdown
    /// shows only the cursor. Stating it once keeps the two-column padding
    /// from drifting apart.
    private func optionRows(showsSelectionMarker: Bool) -> some TerminalView {
        let cursorIndex = cursor.index
        let selected = self.selected
        return ForEachWithID(Array(titles.enumerated()), id: \.offset) { entry in
            HStack {
                Text(entry.offset == cursorIndex ? "\(PickerGlyph.cursor) " : "  ")
                if showsSelectionMarker {
                    Text(entry.offset == selected ? "\(PickerGlyph.selected) " : "  ")
                }
                Text(entry.element)
            }
        }
    }

    /// Up/Down cursor movement, shared by the two list-shaped styles.
    ///
    /// Returns nil for keys that are not vertical movement so the caller can
    /// carry on with its own cases. An unmoved cursor reports `.ignored`, which
    /// is what lets a boundary hit reach the parent.
    private static func verticalMove(_ key: Key, _ cursor: PickerCursor) -> KeyEventResult? {
        switch key {
        case .up: cursor.move(by: -1) != nil ? .handled : .ignored
        case .down: cursor.move(by: 1) != nil ? .handled : .ignored
        default: nil
        }
    }

    // MARK: - Inline

    /// Every option on its own row. Movement and commit are separate steps,
    /// so the cursor and the selection marker are drawn independently.
    private var inlineBody: some TerminalView {
        let cursor = self.cursor
        let commit = self.commit

        return VStack {
            FormLabel(text: label)
            optionRows(showsSelectionMarker: true)
        }
        .focusable()
        .onKeyPress { event in
            guard isEnabled else { return .ignored }
            if let moved = Self.verticalMove(event.key, cursor) { return moved }
            switch event.key {
            case .enter, .character(" "), .activate:
                commit(cursor.index)
                return .handled
            default:
                return .ignored
            }
        }
    }

    // MARK: - Segmented

    /// One row of segments. Left/Right commit as they move — the platform
    /// convention — so there is no separate confirm key.
    ///
    /// When the row cannot fit, this falls back to `inlineBody` rather than
    /// truncating: a clipped segment stays reachable by arrowing past the
    /// visible edge, which would commit a value the user cannot see.
    private var segmentedBody: some TerminalView {
        let cursor = self.cursor
        let commit = self.commit
        let titles = self.titles
        let selected = self.selected

        return VStack {
            if fitsSegmented {
                HStack {
                    FormLabel(text: label)
                    ForEachWithID(Array(titles.enumerated()), id: \.offset) { entry in
                        Text(Self.segmentLabel(entry.element,
                                               isFirst: entry.offset == 0,
                                               isLast: entry.offset == titles.count - 1))
                            .background(orInherit: entry.offset == selected ? theme.backgroundSelected : nil)
                    }
                }
                .focusable()
                .onKeyPress { event in
                    guard isEnabled else { return .ignored }
                    switch event.key {
                    case .left:
                        guard let next = cursor.move(by: -1) else { return .ignored }
                        commit(next)
                        return .handled
                    case .right:
                        guard let next = cursor.move(by: 1) else { return .ignored }
                        commit(next)
                        return .handled
                    default:
                        return .ignored
                    }
                }
            } else {
                inlineBody
            }
        }
    }

    /// Whether the segmented row fits the terminal.
    ///
    /// Read from the environment rather than measured in a `GeometryReader`:
    /// a GR measures the subtree it was *seeded* with at graph construction,
    /// so a fallback that changes the content's height mis-measures and the
    /// taller inline rows overflow their allocated rect. The width is known at
    /// body-eval time, so no measurement seam is needed at all.
    private var fitsSegmented: Bool {
        Self.segmentedWidth(of: titles, label: label) <= terminalWidth
    }

    /// `[ A | B | C ]` — separators between segments, none after the last.
    /// `Light | Dark | Auto` — a separator between segments, and padding only
    /// on the inside.
    ///
    /// The first segment carries no leading space: inside a `Form` that space
    /// would push the control one cell past the shared label column, breaking
    /// the alignment for every other row.
    private static func segmentLabel(_ title: String, isFirst: Bool, isLast: Bool) -> String {
        let leading = isFirst ? "" : " "
        return isLast ? "\(leading)\(title) " : "\(leading)\(title) |"
    }

    /// Width the segmented row needs: the label, then each segment with its
    /// surrounding spaces and trailing separator.
    static func segmentedWidth(of titles: [String], label: String) -> Int {
        // Each segment costs its title plus a trailing space and separator;
        // the first carries no leading space, hence the -1.
        label.count + 1 + titles.reduce(0) { $0 + $1.count + 3 } - 1
    }

    // MARK: - Dropdown

    /// Collapsed to the current value; the list appears on Enter/Space/Down.
    /// Esc closes without committing, Enter commits and closes.
    private var dropdownBody: some TerminalView {
        let cursor = self.cursor
        let commit = self.commit
        let setOpen = self.setOpen
        let isOpen = self.isOpen

        return VStack {
            HStack {
                FormLabel(text: label)
                Text(selected.map { titles[$0] } ?? rawSelection)
                    .foreground(selected == nil ? theme.foregroundMuted : theme.foreground)
                Text(" \(PickerGlyph.collapsed)")
            }
            if isOpen {
                optionRows(showsSelectionMarker: false)
            }
        }
        .focusable()
        .onKeyPress { event in
            guard isEnabled else { return .ignored }
            if !isOpen {
                switch event.key {
                case .enter, .down, .character(" "), .activate:
                    setOpen(true)
                    return .handled
                default:
                    return .ignored
                }
            }
            if let moved = Self.verticalMove(event.key, cursor) { return moved }
            switch event.key {
            case .enter, .activate:
                commit(cursor.index)
                setOpen(false)
                return .handled
            case .escape:
                setOpen(false)
                return .handled
            default:
                return .ignored
            }
        }
    }
}
