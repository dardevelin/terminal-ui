/// Reads the available size and passes it to a content builder.
///
/// The closure is evaluated LAZILY at render time with the actual assigned
/// rect — not at graph-build time with the root terminal size. A nested
/// `GeometryReader` inside padding/border/etc. reports the shrunk inner
/// rect, letting callers (TextInput's virtual scroll, PromptInput soft-wrap,
/// BarChart flex width) compute against true room available.
///
/// ```swift
/// GeometryReader { size in
///     Text("Width: \(size.width)")
/// }
/// ```
public struct GeometryReader<Content: TerminalView>: TerminalView {
    public let content: (Size) -> Content

    public init(@TerminalViewBuilder content: @escaping (Size) -> Content) {
        self.content = content
    }

    /// `body` is never consulted by the renderer — `GeometryReader` is
    /// handled via a dedicated path that re-evaluates `content` with the
    /// render-time rect. The fallback value exists so graph construction
    /// emits a placeholder node before the rebuild happens.
    public var body: Never { fatalError("GeometryReader is rebuilt at render time; body should not be called") }
}
