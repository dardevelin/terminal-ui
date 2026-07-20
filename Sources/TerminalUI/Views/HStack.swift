/// Stacks its children horizontally, left to right.
///
/// Children are laid out in declaration order. `Spacer` children expand
/// to fill remaining horizontal space; siblings split slack equally.
///
/// ```swift
/// HStack {
///     Text("left")
///     Spacer()
///     Text("right")
/// }
/// ```
public struct HStack<Content: TerminalView>: TerminalView {
    public let content: Content

    public init(@TerminalViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never { fatalError() }
}
