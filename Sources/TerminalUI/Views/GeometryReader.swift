/// Takes all the room its container offers, and passes that size to a
/// content builder.
///
/// As in SwiftUI, a `GeometryReader` is greedy: it fills the space it is
/// given on both axes, and when a container that sizes itself to its content
/// asks how big it is, it claims nothing. Give it a size — a flexible slot in
/// a stack, which it fills, or a `.frame` — rather than expecting it to size
/// itself. The closure runs with the rect actually assigned, so a reader
/// inside padding or a border sees the inner rect.
///
/// The reported ``Size`` is in terminal cells — columns wide, rows tall.
/// Reach for `GeometryReader` when content must fill a region and adapt to
/// it: a chart sized to its pane, a list showing as many rows as fit,
/// a layout that switches below a width threshold. When the content's height
/// should follow from its width instead — text that wraps, a row that
/// truncates, a prompt that grows as it is typed into — use ``WidthReader``,
/// which is measured by its content. For plain positioning, stack
/// `alignment:` and `.frame(alignment:)` do the job without a rebuild.
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
    @_documentation(visibility: internal)
    public var body: Never { fatalError("GeometryReader is rebuilt at render time; body should not be called") }
}
