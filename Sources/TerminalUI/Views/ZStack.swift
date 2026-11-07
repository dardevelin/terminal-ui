/// Overlays children on top of each other, front-to-back in declaration order.
///
/// The last child in the block is rendered on top. Each child is offered the
/// stack's size and sits at the size it claims, placed by `alignment`, as in
/// SwiftUI: all of an axis it claims — a ``GeometryReader``, a ``ScrollView``,
/// a ``Divider`` across, `.frame(maxWidth: .infinity)` — and its measured
/// size on one it does not. Later children's cells overwrite earlier ones
/// where they overlap. A child that should cover the whole stack says so with
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)`.
///
/// Overlap is resolved per cell, not per pixel: a front child replaces the
/// character *and* style of every cell it writes, so a small label punches
/// a clean hole through whatever sits behind it and leaves the rest drawn,
/// and the pointer reaches what lies under it beside the label. Reach for
/// `ZStack` when siblings are peers sharing one region — a canvas plus a
/// legend, a box plus a badge. To decorate a single anchor view without
/// changing its layout, prefer the `.overlay(alignment:)` modifier instead.
///
/// The label below covers the first six cells of the block's top row; the
/// block still shows after it and on the rows beneath:
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

    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}
