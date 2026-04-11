/// Reads the available size and passes it to a content builder.
///
/// Usage:
/// ```
/// GeometryReader { size in
///     Text("Width: \(size.width)")
/// }
/// ```
///
/// Note: In the current prototype, size is the proposed rect from layout.
/// Full implementation will provide actual rendered size.
public struct GeometryReader<Content: TerminalView>: TerminalView {
    public let content: (Size) -> Content

    public init(@TerminalViewBuilder content: @escaping (Size) -> Content) {
        self.content = content
    }

    // Body returns content with a placeholder size.
    // The real size comes from the layout pass.
    public var body: some TerminalView {
        content(Size(width: 80, height: 24))
    }
}
