/// A line separator that adapts to its enclosing stack.
///
/// Inside a `VStack`, it renders as a horizontal rule across the container width.
/// Inside an `HStack`, it renders as a vertical rule down the container height.
///
/// ```swift
/// VStack {
///     Text("above")
///     Divider()
///     Text("below")
/// }
/// ```
public struct Divider: TerminalView {
    public init() {}
    public var body: Never { fatalError() }
}
