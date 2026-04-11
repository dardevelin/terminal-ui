/// Reads the available size and passes it to a content builder.
/// Uses the current terminal size from the environment.
///
/// Usage:
/// ```
/// GeometryReader { size in
///     Text("Width: \(size.width)")
/// }
/// ```
public struct GeometryReader<Content: TerminalView>: TerminalView {
    public let content: (Size) -> Content

    public init(@TerminalViewBuilder content: @escaping (Size) -> Content) {
        self.content = content
    }

    public var body: some TerminalView {
        // Read proposed size from render context if available, otherwise fall back to terminal size
        if let proposed = GraphContext.currentProposedSize {
            return content(proposed)
        }
        let termSize = GraphContext.currentEnvironment?.terminalSize ?? .default
        return content(Size(width: termSize.cols, height: termSize.rows))
    }
}
