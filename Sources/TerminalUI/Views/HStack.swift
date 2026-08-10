/// Stacks its children horizontally, left to right.
///
/// Children are laid out in declaration order. `Spacer` children expand
/// to fill remaining horizontal space; siblings split slack equally.
///
/// Layout is computed in whole terminal cells: `spacing: 1` inserts one
/// blank column between children. A ``Spacer`` between two children is
/// the idiom for a full-width bar with content pushed to both edges —
/// status bars, headers, key-hint rows. Use ``VStack`` for a column,
/// ``ZStack`` to layer views in the same rect, and ``SplitView`` when
/// panes should divide the width by ratio rather than by content size.
///
/// ```swift
/// HStack {
///     Text("left")
///     Spacer()
///     Text("right")
/// }
///
/// HStack(alignment: .bottom, spacing: 2) {
///     Text("tall\nrows\nhere").foreground(.gray)
///     Text("bottom").foreground(.yellow)
/// }
/// ```
public struct HStack<Content: TerminalView>: TerminalView {
    /// The children, in declaration order (left to right).
    public let content: Content
    /// Cross-axis placement for children shorter than the stack.
    public let alignment: VerticalAlignment
    /// Blank columns between adjacent children. Never negative — the
    /// initializer clamps.
    public let spacing: Int

    /// Creates a horizontal stack.
    ///
    /// - Parameters:
    ///   - alignment: where shorter children sit down the stack. Defaults to
    ///     `.top` rather than SwiftUI's `.center`, for the reason `VStack`
    ///     documents: existing layouts were written against top alignment.
    ///   - spacing: blank cells between children, none by default.
    ///   - content: the children, left to right.
    public init(
        alignment: VerticalAlignment = .top,
        spacing: Int = 0,
        @TerminalViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.alignment = alignment
        self.spacing = max(0, spacing)
    }

    public var body: Never { fatalError() }
}
