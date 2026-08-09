/// A line separator that adapts to its enclosing stack.
///
/// Inside a `VStack`, it renders as a horizontal rule across the container width.
/// Inside an `HStack`, it renders as a vertical rule down the container height.
///
/// The rule is exactly one cell thick — drawn with box-drawing glyphs, so
/// it lines up with ``BorderStyle`` frames — and stretches edge to edge of
/// the container on its long axis. It inherits the ambient text style,
/// which means a dim or colored divider comes from the same modifiers as
/// any other view. Reach for `Divider` to separate sections inside one
/// container; when the two sides are independent resizable panes, that is
/// ``SplitView``'s job (it draws its own dividers between panes).
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
