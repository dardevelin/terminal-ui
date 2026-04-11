/// Overlays children on top of each other.
/// Last child renders on top.
public struct ZStack<Content: TerminalView>: TerminalView {
    public let content: Content

    public init(@TerminalViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never { fatalError() }
}
