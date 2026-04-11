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
        // Read terminal size from environment for actual dimensions
        let termSize = GraphContext.currentEnvironment?.terminalSize ?? TerminalSize(cols: 80, rows: 24)
        return content(Size(width: termSize.cols, height: termSize.rows))
    }
}
