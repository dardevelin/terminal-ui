/// Reads the available size and passes it to a content builder.
///
/// The closure is evaluated LAZILY at render time with the actual assigned
/// rect — not at graph-build time with the root terminal size. A nested
/// `GeometryReader` inside padding/border/etc. reports the shrunk inner
/// rect, letting callers (TextInput's virtual scroll, PromptInput soft-wrap,
/// BarChart flex width) compute against true room available.
///
/// The reported ``Size`` is in terminal cells — columns wide, rows tall.
/// Reach for `GeometryReader` when content must adapt to the room it
/// actually got: wrapping long lines to the container width, sizing a
/// chart to fill a pane, switching layouts below a width threshold. For
/// plain positioning, stack `alignment:` and `.frame(alignment:)` do the
/// job without a size-dependent rebuild.
///
/// > Important: Project `@TerminalState` bindings (`$state`) in `body`
/// > and capture them; a `$` projection written inside the
/// > `GeometryReader` closure resolves against the wrong graph node,
/// > because the closure runs later, during render.
///
/// ```swift
/// GeometryReader { size in
///     Text("proposed: \(size.width)×\(size.height)")
///         .foreground(.magenta)
/// }
/// .frame(height: 2)
/// ```
public struct GeometryReader<Content: TerminalView>: TerminalView {
    /// Builder invoked at render time with the rect actually assigned,
    /// in cells. Re-invoked whenever that rect changes (terminal resize,
    /// surrounding layout shift).
    public let content: (Size) -> Content

    /// Creates a size-reading container.
    ///
    /// - Parameter content: builds the subtree for a concrete available
    ///   size. Runs at render time, so keep it a pure function of `size`
    ///   and previously captured values.
    public init(@TerminalViewBuilder content: @escaping (Size) -> Content) {
        self.content = content
    }

    /// `body` is never consulted by the renderer — `GeometryReader` is
    /// handled via a dedicated path that re-evaluates `content` with the
    /// render-time rect. The fallback value exists so graph construction
    /// emits a placeholder node before the rebuild happens.
    public var body: Never { fatalError("GeometryReader is rebuilt at render time; body should not be called") }
}
