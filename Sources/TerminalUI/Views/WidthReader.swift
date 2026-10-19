/// Lays its content out at the width it is given, and is as tall as that
/// content turns out to be.
///
/// This is the size-reading container for content whose height follows from
/// its width — text that wraps, a row that truncates to fit, a prompt that
/// grows as it is typed into. The content receives the width only; its height
/// is measured, never handed in, so it cannot read back the dimension it
/// decides. That is the difference from ``GeometryReader``, which is told both
/// dimensions by its container and takes all the room it is offered.
///
/// Horizontally it behaves like a `GeometryReader`: it takes the width its
/// container gives it and claims none of its own. Vertically it is content:
/// a stack measures it, and a `ScrollView` scrolls it.
///
/// ```swift
/// WidthReader { width in
///     Text(spans: wrapped(message, to: width))
/// }
/// ```
///
/// SwiftUI has no direct counterpart; it expresses this through the `Layout`
/// protocol's ideal size for a proposed width.
///
/// > Important: As with `GeometryReader`, project `@TerminalState` bindings
/// > (`$state`) in `body` and capture them — a `$` projection written inside
/// > the closure resolves against the wrong graph node, because the closure
/// > runs later.
public struct WidthReader<Content: TerminalView>: TerminalView {
    /// Builds the content for a width, in cells. Re-invoked when the width
    /// changes or the state it reads does.
    public let content: (Int) -> Content

    /// Creates a width-reading container.
    ///
    /// - Parameter content: builds the subtree for a concrete width. Keep it
    ///   a pure function of the width and of state captured from `body`.
    public init(@TerminalViewBuilder content: @escaping (Int) -> Content) {
        self.content = content
    }

    /// Never consulted: the graph rebuilds `content` for each width a pass
    /// asks about.
    public var body: Never { fatalError("WidthReader is rebuilt per width; body should not be called") }
}
