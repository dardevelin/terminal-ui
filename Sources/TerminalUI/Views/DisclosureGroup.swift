/// A label that shows or hides its content beneath it.
///
/// The label row takes a disclosure mark — `▾` open, `▸` closed — and is one
/// Tab stop: Enter, Space or a click flips it, → opens it and ← closes it,
/// as a row of a ``TreeView`` does. Closed, the content takes no rows, so
/// what follows moves up into the room: a pane of a stacked panel folds
/// away with one, leaving the panes below the space.
///
/// ```swift
/// DisclosureGroup(isExpanded: $showsFiles) {
///     List(files, selection: $selected) { Text($0.path) }
/// } label: {
///     Text("\(files.count) files changed")
/// }
/// ```
///
/// SwiftUI parity: `DisclosureGroup(isExpanded:content:label:)` and
/// `DisclosureGroup(_:isExpanded:content:)`.
public struct DisclosureGroup<Label: TerminalView, Content: TerminalView>: TerminalView {
    /// Whether the content is shown.
    public let isExpanded: Binding<Bool>
    /// What the group shows and hides.
    public let content: Content
    /// The row that names the content and folds it.
    public let label: Label

    @TerminalEnvironment(\.isEnabled) private var isEnabled
    @TerminalEnvironment(\.theme) private var theme

    /// Creates a group whose label is a view.
    public init(
        isExpanded: Binding<Bool>,
        @TerminalViewBuilder content: () -> Content,
        @TerminalViewBuilder label: () -> Label
    ) {
        self.isExpanded = isExpanded
        self.content = content()
        self.label = label()
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let theme = theme
        let expanded = isExpanded.get()
        return VStack(spacing: 0) {
            HStack(spacing: 1) {
                Text(expanded ? "▾" : "▸").foreground(theme.foregroundMuted)
                label
            }
            .labelForeground(enabled: isEnabled, theme: theme)
            .focusable()
            .onKeyPress { [isExpanded] event in
                switch event.key {
                case .enter, .activate, .character(" "):
                    isExpanded.set(!isExpanded.get())
                case .right where !isExpanded.get():
                    isExpanded.set(true)
                case .left where isExpanded.get():
                    isExpanded.set(false)
                // At the end already: taken, so the arrow does not move
                // focus away from the group it was aimed at.
                case .right, .left:
                    break
                default:
                    return .ignored
                }
                return .handled
            }
            if expanded {
                content
            }
        }
    }
}

extension DisclosureGroup where Label == Text {
    /// Creates a group whose label is a title.
    public init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @TerminalViewBuilder content: () -> Content
    ) {
        self.init(isExpanded: isExpanded, content: content) { Text(title) }
    }
}
