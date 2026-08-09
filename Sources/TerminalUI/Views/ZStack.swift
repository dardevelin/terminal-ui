/// Overlays children on top of each other, front-to-back in declaration order.
///
/// The last child in the block is rendered on top. All children receive the
/// same container rect and render within it; later children's cells overwrite
/// earlier ones where they overlap.
///
/// ```swift
/// ZStack {
///     Text("background")
///     Text(" FOCUS ").foreground(.cyan).bold()
/// }
/// ```
public struct ZStack<Content: TerminalView>: TerminalView {
    public let content: Content
    public let alignment: Alignment

    /// - Parameters:
    ///   - alignment: where children smaller than the stack sit.
    ///     `.topLeading` by default, matching the other two stacks.
    ///   - content: the children, back to front — later children draw on top.
    public init(
        alignment: Alignment = .topLeading,
        @TerminalViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.alignment = alignment
    }

    public var body: Never { fatalError() }
}
