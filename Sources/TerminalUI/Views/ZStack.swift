/// Overlays children on top of each other, front-to-back in declaration order.
///
/// The last child in the block is rendered on top. All children receive the
/// same container rect and render within it; later children's cells overwrite
/// earlier ones where they overlap.
///
/// Overlap is resolved per cell, not per pixel: a front child replaces the
/// character *and* style of every cell it writes, so a small label punches
/// a clean hole through whatever sits behind it. Reach for `ZStack` when
/// siblings are peers sharing one region — a canvas plus a legend, a box
/// plus a badge. To decorate a single anchor view without changing its
/// layout, prefer the `.overlay(alignment:)` modifier instead.
///
/// ```swift
/// ZStack {
///     Text("◼◼◼◼◼◼◼◼◼◼\n◼◼◼◼◼◼◼◼◼◼\n◼◼◼◼◼◼◼◼◼◼")
///         .foreground(.ansi256(238))
///     Text(" OVER ").foreground(.cyan).bold()
/// }
/// ```
public struct ZStack<Content: TerminalView>: TerminalView {
    /// The children, back to front — the last one drawn wins overlapping cells.
    public let content: Content
    /// Where children smaller than the stack's rect are placed.
    public let alignment: Alignment

    /// Creates a depth stack.
    ///
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
