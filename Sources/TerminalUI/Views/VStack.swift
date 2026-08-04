/// Stacks its children vertically, top to bottom.
///
/// Children are laid out in declaration order with no gaps by default.
/// `Spacer` children expand to fill remaining vertical space. Sibling
/// `Spacer` instances split the slack equally.
///
/// ```swift
/// VStack {
///     Text("title").bold()
///     Divider()
///     Text("body")
/// }
/// ```
public struct VStack<Content: TerminalView>: TerminalView {
    public let content: Content
    public let alignment: HorizontalAlignment
    public let spacing: Int

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
