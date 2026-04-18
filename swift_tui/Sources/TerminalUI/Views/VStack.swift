/// Stacks its children vertically, top to bottom.
///
/// Children are laid out in declaration order with no gaps by default.
/// `Spacer` children expand to fill remaining vertical space. Sibling
/// `Spacer` instances split the slack equally.
///
/// ```swift
/// VStack {
///     Text("title").bold()
///     Divider()
///     Text("body")
/// }
/// ```
public struct VStack<Content: TerminalView>: TerminalView {
    public let content: Content

    public init(@TerminalViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never { fatalError() }
}
