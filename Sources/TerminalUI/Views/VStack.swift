/// Stacks its children vertically, top to bottom.
///
/// Children are laid out in declaration order with no gaps by default.
/// `Spacer` children expand to fill remaining vertical space. Sibling
/// `Spacer` instances split the slack equally.
///
/// Layout is computed in whole terminal cells: one row of `Text` is one
/// cell tall, and `spacing: 1` inserts one visibly blank row — there is
/// no sub-cell hairline to fall back on. Reach for `VStack` to arrange a
/// column of content; use ``HStack`` for a row, ``ZStack`` to layer views
/// in the same rect, ``ScrollView`` when the column may outgrow the
/// viewport, and ``List`` when rows need selection and a row cursor.
///
/// ```swift
/// VStack {
///     Text("title").bold()
///     Divider()
///     Text("body")
/// }
///
/// VStack(alignment: .trailing, spacing: 1) {
///     Text("one").foreground(.cyan)
///     Text("three").foreground(.cyan)
/// }
/// ```
public struct VStack<Content: TerminalView>: TerminalView {
    /// The children, in declaration order (top to bottom).
    public let content: Content
    /// Cross-axis placement for children narrower than the stack.
    public let alignment: HorizontalAlignment
    /// Blank rows between adjacent children. Never negative — the
    /// initializer clamps.
    public let spacing: Int

    /// Creates a vertical stack.
    ///
    /// - Parameters:
    ///   - alignment: where narrower children sit across the stack. Defaults
    ///     to `.leading`, not SwiftUI's `.center`: a terminal reads
    ///     left-to-right off a fixed grid, every existing layout in this
    ///     framework was written against that, and centring by default would
    ///     silently re-place all of them. Ask for `.center` and you get it.
    ///   - spacing: blank cells between children. Defaults to none — the unit
    ///     here is a whole cell, so a default gap would be a visible design
    ///     decision imposed on every stack rather than the hairline SwiftUI
    ///     inserts.
    ///   - content: the children, top to bottom.
    public init(
        alignment: HorizontalAlignment = .leading,
        spacing: Int = 0,
        @TerminalViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.alignment = alignment
        self.spacing = max(0, spacing)
    }

    public var body: Never { fatalError() }
}
