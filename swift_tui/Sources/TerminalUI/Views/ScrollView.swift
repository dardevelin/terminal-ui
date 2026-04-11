/// A view that scrolls its content vertically.
/// Shows a subset of content based on the scroll offset.
///
/// Usage:
/// ```
/// ScrollView {
///     ForEach(items) { item in
///         Text(item.name)
///     }
/// }
/// ```
public struct ScrollView<Content: TerminalView>: TerminalView {
    public let content: Content
    public let offset: Int

    public init(offset: Int = 0, @TerminalViewBuilder content: () -> Content) {
        self.content = content()
        self.offset = offset
    }

    public var body: Never { fatalError() }
}
